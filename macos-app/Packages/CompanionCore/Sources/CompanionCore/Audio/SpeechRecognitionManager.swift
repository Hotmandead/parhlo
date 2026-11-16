@preconcurrency import AVFoundation
import Foundation
import Observation
import os
@preconcurrency import Speech

/// Thread-safe holder allowing audio tap threads to append `AVAudioPCMBuffer`s synchronously.
private final class ActiveRecognitionRequestBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(initialState: nil)

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { $0 = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let request = lock.withLock { $0 }
        request?.append(buffer)
    }
}

/// Streams `AVAudioPCMBuffer` mic audio into Apple's `SFSpeechRecognizer` for live speech-to-text transcripts.
@MainActor
@Observable
public final class SpeechRecognitionManager {
    public private(set) var isListening: Bool = false
    public private(set) var latestTranscript: String = ""
    public private(set) var lastError: String?

    @ObservationIgnored public var onTranscriptUpdate: (@MainActor (String, Bool) -> Void)?

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let activeRequestBox = ActiveRecognitionRequestBox()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    public init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Requests Speech Recognition authorization if not yet determined, returning whether recognition is authorized.
    public func ensureAuthorized() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized {
            return true
        }
        guard current == .notDetermined else {
            lastError = "Speech Recognition permission denied in System Settings."
            return false
        }
        let status = await Self.requestAuthorizationStatus()
        if status != .authorized {
            lastError = "Speech Recognition permission not granted."
        }
        return status == .authorized
    }

    /// Starts an on-device (when supported) streaming `SFSpeechAudioBufferRecognitionRequest`.
    public func start() async {
        stop()
        lastError = nil
        latestTranscript = ""

        guard await ensureAuthorized() else { return }
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognizer unavailable for current locale."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        self.activeRequestBox.set(request)
        self.isListening = true

        self.recognitionTask = Self.startRecognitionTask(
            recognizer: recognizer,
            request: request
        ) { [weak self] transcript, isFinal, errorMessage, hasError in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let transcript, !transcript.isEmpty {
                    self.latestTranscript = transcript
                    self.onTranscriptUpdate?(transcript, isFinal)
                }
                if let errorMessage, hasError {
                    self.lastError = errorMessage
                }
                if isFinal || hasError {
                    self.activeRequestBox.set(nil)
                    self.isListening = false
                }
            }
        }
    }

    /// Appends a live audio buffer synchronously from `AVAudioEngine`'s tap thread before CoreAudio reuses it.
    nonisolated public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        activeRequestBox.append(buffer)
    }

    /// Ends audio input and cleans up the active recognition task.
    public func stop() {
        activeRequestBox.set(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    // Keep Speech framework callbacks off @MainActor so Swift 6 does not assert main-queue execution.
    nonisolated private static func requestAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated private static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onEvent: @escaping @Sendable (String?, Bool, String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            onEvent(transcript, isFinal, errorMessage, error != nil)
        }
    }
}
