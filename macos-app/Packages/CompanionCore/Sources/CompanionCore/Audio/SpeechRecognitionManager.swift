@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Speech

/// Streams `AVAudioPCMBuffer` mic audio into Apple's `SFSpeechRecognizer` for live speech-to-text transcripts.
@MainActor
@Observable
public final class SpeechRecognitionManager {
    public private(set) var isListening: Bool = false
    public private(set) var latestTranscript: String = ""
    public private(set) var lastError: String?

    @ObservationIgnored public var onTranscriptUpdate: (@MainActor (String, Bool) -> Void)?

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
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
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in
                continuation.resume(returning: result)
            }
        }
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
        self.isListening = true

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let transcript, !transcript.isEmpty {
                    self.latestTranscript = transcript
                    self.onTranscriptUpdate?(transcript, isFinal)
                }
                if let errorMessage, error != nil {
                    self.lastError = errorMessage
                }
                if isFinal || error != nil {
                    self.isListening = false
                }
            }
        }
    }

    /// Appends a live audio buffer from `AVAudioEngine`'s input tap into the active recognition request.
    nonisolated public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            self?.recognitionRequest?.append(buffer)
        }
    }

    /// Ends audio input and cleans up the active recognition task.
    public func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }
}
