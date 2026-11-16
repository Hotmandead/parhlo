import AppKit
import Foundation
import Observation

/// Coordinates live voice capture, <= 1 FPS screen/AX capture, WebSocket bridging, and overlay rendering.
@MainActor
@Observable
public final class AppCoordinator {
    public let overlayStore: OverlayStateStore
    public let permissionsManager: PermissionsManager
    public let privacyFilter: PrivacyFilter
    public let captureEngine: CaptureEngine
    public let webSocketClient: SidecarWebSocketClient
    public let audioManager: AudioEngineManager
    public let hotkeyManager: GlobalHotkeyManager
    public let overlayController: OverlayWindowController

    public private(set) var isSessionActive: Bool = false
    public private(set) var lastStatusError: String?

    public init(
        sidecarURL: URL = SidecarWebSocketClient.defaultURL,
        overlayStore: OverlayStateStore? = nil,
        permissionsManager: PermissionsManager? = nil,
        hotkeyMode: HotkeyActivationMode = .smartTapOrHold
    ) {
        let store = overlayStore ?? OverlayStateStore()
        let permissions = permissionsManager ?? PermissionsManager()
        let privacy = PrivacyFilter(overlayStore: store)
        let capture = CaptureEngine(privacyFilter: privacy)
        let ws = SidecarWebSocketClient(url: sidecarURL, overlayStore: store)
        let audio = AudioEngineManager()
        let hotkey = GlobalHotkeyManager(mode: hotkeyMode)
        let overlay = OverlayWindowController(store: store)

        self.overlayStore = store
        self.permissionsManager = permissions
        self.privacyFilter = privacy
        self.captureEngine = capture
        self.webSocketClient = ws
        self.audioManager = audio
        self.hotkeyManager = hotkey
        self.overlayController = overlay

        wireCallbacks()
    }

    /// Installs global `Control+Option` monitoring on app launch.
    public func bootstrap() {
        hotkeyManager.startMonitoring()
    }

    /// Toggles the active screen + voice session on or off.
    public func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    /// Starts WebSocket connection, `AVAudioEngine` voice I/O, on-demand screen capture, and HUD overlay.
    public func startSession() {
        guard !isSessionActive else { return }
        lastStatusError = nil
        permissionsManager.refresh()

        isSessionActive = true
        hotkeyManager.syncSessionActive(true)
        privacyFilter.startObserving()

        overlayController.showOverlay()
        overlayStore.apply(HudStateMessage(
            state: privacyFilter.isPaused ? .privacyPaused : .listening,
            transcriptSnippet: privacyFilter.isPaused ? "Paused for protected app" : "Listening… (Control+Option to stop)"
        ))

        webSocketClient.connect()

        do {
            try audioManager.start()
        } catch {
            lastStatusError = "Audio start failed: \(error.localizedDescription)"
        }

        captureEngine.startSessionCapture(interval: 1.0) { [weak self] contextMessage in
            await self?.sendScreenContextIfConnected(contextMessage)
        }

        Task { @MainActor [weak self] in
            await self?.sendStartControlWhenReady()
        }
    }

    /// Stops voice/screen capture, clears active annotations, and closes the session.
    public func stopSession() {
        guard isSessionActive else { return }

        isSessionActive = false
        hotkeyManager.syncSessionActive(false)
        captureEngine.stopSessionCapture()
        audioManager.stop()
        privacyFilter.stopObserving()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.webSocketClient.send(SessionControlMessage(action: .stopSession))
        }

        overlayStore.clearAll()
        overlayStore.apply(HudStateMessage(state: .idle, transcriptSnippet: nil))
        overlayController.hideOverlay()
    }

    /// Immediately stops playback and fades annotations, notifying the sidecar of manual barge-in.
    public func triggerManualBargeIn() {
        audioManager.stopPlaybackImmediately()
        overlayStore.handleBargeIn(BargeInMessage(reason: .manual))

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.webSocketClient.send(SessionControlMessage(action: .bargeInManual))
        }
    }

    /// Shows the Phase 2/3 visual overlay demo without requiring a live sidecar connection.
    public func triggerDemoAnnotations() {
        overlayController.showOverlay()
        overlayStore.loadDemoAnnotations(for: overlayController.currentOverlaySize)
    }

    /// Clears all annotations and hides the overlay when no session is active.
    public func clearOverlay() {
        overlayStore.clearAll()
        if !isSessionActive {
            overlayStore.apply(HudStateMessage(state: .idle, transcriptSnippet: nil))
            overlayController.hideOverlay()
        }
    }

    private func wireCallbacks() {
        webSocketClient.onAudioDown = { [weak self] audioMessage in
            guard let data = Data(base64Encoded: audioMessage.pcmB64) else { return }
            Task { @MainActor [weak self] in
                self?.audioManager.enqueuePlayback(pcm24kData: data)
            }
        }

        webSocketClient.onBargeIn = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioManager.stopPlaybackImmediately()
            }
        }

        audioManager.onAudioChunk = { [weak self] pcm16kData in
            let b64 = pcm16kData.base64EncodedString()
            Task { @MainActor [weak self] in
                guard let self,
                      self.isSessionActive,
                      self.webSocketClient.connectionState == .connected else {
                    return
                }
                try? await self.webSocketClient.send(AudioUpMessage(pcmB64: b64))
            }
        }

        audioManager.onLocalVoiceActivity = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive else { return }
                self.audioManager.stopPlaybackImmediately()
            }
        }

        hotkeyManager.onSessionRequested = { [weak self] active in
            guard let self else { return }
            if active && !self.isSessionActive {
                self.startSession()
            } else if !active && self.isSessionActive {
                self.stopSession()
            }
        }
    }

    private func sendStartControlWhenReady() async {
        // Wait briefly for WebSocket handshake if connecting.
        for _ in 0..<20 {
            guard isSessionActive else { return }
            if webSocketClient.connectionState == .connected {
                try? await webSocketClient.send(SessionControlMessage(action: .startSession))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func sendScreenContextIfConnected(_ message: ScreenContextMessage) async {
        guard isSessionActive, webSocketClient.connectionState == .connected else { return }
        try? await webSocketClient.send(message)
    }
}
