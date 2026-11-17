import Foundation
import Observation
import SwiftUI

/// Connection lifecycle state for `SidecarWebSocketClient`.
public enum WebSocketConnectionState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    public var displayTitle: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        }
    }
}

/// Errors thrown when attempting to transmit upstream payloads over an inactive WebSocket.
public enum SidecarWebSocketError: Error, Sendable, Equatable {
    case notConnected
    case encodingFailed
}

private final class WebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable (URLSessionWebSocketTask) -> Void)?
    var onClose: (@Sendable (URLSessionWebSocketTask, String?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?(webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        let description: String?
        if closeCode != .normalClosure && closeCode != .invalid {
            if let reasonText, !reasonText.isEmpty {
                description = "WebSocket closed (\(closeCode.rawValue)): \(reasonText)"
            } else {
                description = "WebSocket closed (\(closeCode.rawValue))"
            }
        } else {
            description = nil
        }
        onClose?(webSocketTask, description)
    }
}

/// `URLSessionWebSocketTask` bridge connecting `macos-app` to `agent-sidecar` on `ws://127.0.0.1:8765`.
@MainActor
@Observable
public final class SidecarWebSocketClient {
    public static let defaultURL = URL(string: "ws://127.0.0.1:8765")!

    public let url: URL
    public private(set) var connectionState: WebSocketConnectionState = .disconnected
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored public var onAudioDown: (@MainActor @Sendable (AudioDownMessage) -> Void)?
    @ObservationIgnored public var onBargeIn: (@MainActor @Sendable (BargeInMessage) -> Void)?
    @ObservationIgnored public var onInputTranscript: (@MainActor @Sendable (InputTranscriptMessage) -> Void)?
    @ObservationIgnored public var onConnectionStateChanged: (@MainActor @Sendable (WebSocketConnectionState) -> Void)?

    @ObservationIgnored private weak var overlayStore: OverlayStateStore?
    @ObservationIgnored private let initialReconnectDelay: TimeInterval
    @ObservationIgnored private let maxReconnectDelay: TimeInterval
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    @ObservationIgnored private let delegateProxy = WebSocketDelegateProxy()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var shouldStayConnected = false
    @ObservationIgnored private var reconnectAttempt = 0

    public init(
        url: URL = SidecarWebSocketClient.defaultURL,
        overlayStore: OverlayStateStore? = nil,
        initialReconnectDelay: TimeInterval = 0.5,
        maxReconnectDelay: TimeInterval = 16.0
    ) {
        self.url = url
        self.overlayStore = overlayStore
        self.initialReconnectDelay = max(0.1, initialReconnectDelay)
        self.maxReconnectDelay = max(initialReconnectDelay, maxReconnectDelay)

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)

        delegateProxy.onOpen = { [weak self] task in
            Task { @MainActor [weak self] in
                self?.handleSocketOpened(for: task)
            }
        }
        delegateProxy.onClose = { [weak self] task, reasonDescription in
            Task { @MainActor [weak self] in
                self?.handleSocketClosedOrFailed(for: task, errorDescription: reasonDescription)
            }
        }
    }

    deinit {
        receiveTask?.cancel()
        reconnectTask?.cancel()
        session.invalidateAndCancel()
    }

    public func attachOverlayStore(_ store: OverlayStateStore?) {
        self.overlayStore = store
    }

    /// Computes capped exponential backoff delay for a reconnect attempt (0-indexed).
    nonisolated public static func reconnectDelay(
        attempt: Int,
        initialDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 16.0
    ) -> TimeInterval {
        let safeAttempt = max(0, attempt)
        let multiplier = pow(2.0, Double(safeAttempt))
        return min(maxDelay, max(0.05, initialDelay) * multiplier)
    }

    /// Opens the WebSocket connection to `agent-sidecar` and starts the receive loop.
    public func connect() {
        guard !shouldStayConnected || connectionState == .disconnected else { return }
        shouldStayConnected = true
        reconnectAttempt = 0
        openConnection()
    }

    /// Gracefully closes the WebSocket connection and cancels any pending reconnects.
    public func disconnect() {
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        updateConnectionState(.disconnected)
    }

    /// Sends a `SessionControlMessage` (`start_session`, `stop_session`, `barge_in_manual`).
    public func send(_ message: SessionControlMessage) async throws {
        try await sendEncodable(message)
    }

    /// Sends a redacted `ScreenContextMessage` frame and AX snapshot.
    public func send(_ message: ScreenContextMessage) async throws {
        try await sendEncodable(message)
    }

    /// Sends an upstream 16 kHz PCM `AudioUpMessage`.
    public func send(_ message: AudioUpMessage) async throws {
        try await sendEncodable(message)
    }

    /// Sends an upstream typed/dictated `TextUpMessage`.
    public func send(_ message: TextUpMessage) async throws {
        try await sendEncodable(message)
    }

    /// Sends any `UpstreamMessage` variant as a JSON text frame.
    public func send(_ message: UpstreamMessage) async throws {
        try await sendEncodable(message)
    }

    /// Decodes a raw JSON text payload and dispatches it to `OverlayStateStore` and audio/barge-in callbacks.
    @discardableResult
    public func handleIncomingText(_ text: String) throws -> DownstreamEvent {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Invalid UTF-8 WebSocket text")
            )
        }
        return try handleIncomingData(data)
    }

    /// Decodes raw UTF-8 JSON bytes and dispatches the resulting `DownstreamEvent`.
    @discardableResult
    public func handleIncomingData(_ data: Data) throws -> DownstreamEvent {
        let event = try decoder.decode(DownstreamEvent.self, from: data)
        dispatch(event)
        return event
    }

    public func dispatch(_ event: DownstreamEvent) {
        switch event {
        case .drawCommand(let command):
            withAnimation(.easeOut(duration: 0.18)) {
                overlayStore?.apply(command)
            }
        case .hudState(let state):
            withAnimation(.easeOut(duration: 0.18)) {
                overlayStore?.apply(state)
            }
        case .bargeIn(let bargeIn):
            withAnimation(.easeOut(duration: 0.18)) {
                overlayStore?.handleBargeIn(bargeIn)
            }
            onBargeIn?(bargeIn)
        case .audioDown(let chunk):
            onAudioDown?(chunk)
        case .inputTranscript(let transcript):
            onInputTranscript?(transcript)
        }
    }

    private func sendEncodable<T: Encodable>(_ payload: T) async throws {
        guard let task = webSocketTask, connectionState == .connected else {
            throw SidecarWebSocketError.notConnected
        }
        let data = try encoder.encode(payload)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw SidecarWebSocketError.encodingFailed
        }
        try await task.send(.string(jsonString))
    }

    private func openConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        updateConnectionState(reconnectAttempt == 0 ? .connecting : .reconnecting)

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 8 * 1024 * 1024
        self.webSocketTask = task
        task.resume()

        startReceiveLoop(for: task)
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        receiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, self.webSocketTask === task else { break }

                    if self.connectionState != .connected {
                        self.handleSocketOpened(for: task)
                    }

                    switch message {
                    case .string(let text):
                        do {
                            try self.handleIncomingText(text)
                        } catch {
                            self.lastErrorDescription = "Failed to decode sidecar message: \(error.localizedDescription)"
                        }
                    case .data(let data):
                        do {
                            try self.handleIncomingData(data)
                        } catch {
                            self.lastErrorDescription = "Failed to decode sidecar binary message: \(error.localizedDescription)"
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, self.webSocketTask === task, !Task.isCancelled else { break }
                    self.handleSocketClosedOrFailed(for: task, errorDescription: error.localizedDescription)
                    break
                }
            }
        }
    }

    internal var activeWebSocketTaskForTesting: URLSessionWebSocketTask? {
        webSocketTask
    }

    internal func makeDetachedTaskForTesting() -> URLSessionWebSocketTask {
        session.webSocketTask(with: url)
    }

    internal func handleSocketOpened(for task: URLSessionWebSocketTask) {
        guard self.webSocketTask === task else { return }
        reconnectAttempt = 0
        lastErrorDescription = nil
        updateConnectionState(.connected)
    }

    internal func handleSocketClosedOrFailed(for task: URLSessionWebSocketTask, errorDescription: String?) {
        guard self.webSocketTask === task else { return }
        guard shouldStayConnected else {
            updateConnectionState(.disconnected)
            return
        }
        guard reconnectTask == nil else { return }

        if let errorDescription {
            lastErrorDescription = errorDescription
        }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        let delay = Self.reconnectDelay(
            attempt: reconnectAttempt,
            initialDelay: initialReconnectDelay,
            maxDelay: maxReconnectDelay
        )
        reconnectAttempt += 1
        updateConnectionState(.reconnecting)

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.shouldStayConnected else { return }
            self.reconnectTask = nil
            self.openConnection()
        }
    }

    private func updateConnectionState(_ newState: WebSocketConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        onConnectionStateChanged?(newState)
    }
}
