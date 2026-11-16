@preconcurrency import AVFoundation
import Foundation
import Observation
import os
@preconcurrency import Speech

/// Thread-safe holder allowing audio tap threads to append `AVAudioPCMBuffer`s synchronously.
private final class ActiveRecognitionRequestBox: @unchecked Sendable {
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var converter: AVAudioConverter?
        var sourceFormat: AVAudioFormat?
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock { state in
            state.request = request
            if request == nil {
                state.converter = nil
                state.sourceFormat = nil
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (request, normalizedBuffer): (SFSpeechAudioBufferRecognitionRequest?, AVAudioPCMBuffer?) = lock.withLock { state in
            guard let request = state.request else {
                return (nil, nil)
            }
            let normalized = SpeechRecognitionManager.normalizeBufferForSpeech(
                buffer,
                cachedConverter: &state.converter,
                cachedSourceFormat: &state.sourceFormat
            )
            return (request, normalized)
        }

        if let request, let normalizedBuffer {
            request.append(normalizedBuffer)
        }
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
    @ObservationIgnored public var onError: (@MainActor (String) -> Void)?

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let activeRequestBox = ActiveRecognitionRequestBox()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var shouldRemainListening: Bool = false
    @ObservationIgnored private var committedTranscriptPrefix: String = ""
    @ObservationIgnored private var didReceiveTranscriptInCurrentTask: Bool = false
    @ObservationIgnored private var usedOnDeviceFallback: Bool = false

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
        committedTranscriptPrefix = ""
        didReceiveTranscriptInCurrentTask = false
        usedOnDeviceFallback = false

        guard await ensureAuthorized() else {
            if let lastError {
                onError?(lastError)
            }
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            let message = "Speech recognizer unavailable for current locale."
            lastError = message
            onError?(message)
            return
        }

        shouldRemainListening = true
        beginRecognitionTask(
            using: recognizer,
            requireOnDevice: recognizer.supportsOnDeviceRecognition
        )
    }

    private func beginRecognitionTask(using recognizer: SFSpeechRecognizer, requireOnDevice: Bool) {
        guard shouldRemainListening else { return }

        sessionGeneration &+= 1
        let gen = sessionGeneration
        didReceiveTranscriptInCurrentTask = false

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if requireOnDevice && recognizer.supportsOnDeviceRecognition {
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
                guard let self, self.sessionGeneration == gen else { return }

                if let transcript, !transcript.isEmpty {
                    self.didReceiveTranscriptInCurrentTask = true
                    let combined = self.combinedTranscript(for: transcript)
                    self.latestTranscript = combined
                    self.onTranscriptUpdate?(combined, isFinal)
                }

                if hasError {
                    if requireOnDevice && !self.didReceiveTranscriptInCurrentTask && !self.usedOnDeviceFallback && self.shouldRemainListening {
                        self.usedOnDeviceFallback = true
                        self.beginRecognitionTask(using: recognizer, requireOnDevice: false)
                        return
                    }

                    if let errorMessage {
                        self.lastError = errorMessage
                        self.onError?(errorMessage)
                    }
                    self.activeRequestBox.set(nil)
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.shouldRemainListening = false
                    self.isListening = false
                    return
                }

                if isFinal {
                    if self.shouldRemainListening {
                        self.committedTranscriptPrefix = self.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.beginRecognitionTask(
                            using: recognizer,
                            requireOnDevice: recognizer.supportsOnDeviceRecognition && !self.usedOnDeviceFallback
                        )
                    } else {
                        self.activeRequestBox.set(nil)
                        self.isListening = false
                    }
                }
            }
        }
    }

    private func combinedTranscript(for segment: String) -> String {
        let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedTranscriptPrefix.isEmpty else { return segment }
        guard !trimmedSegment.isEmpty else { return committedTranscriptPrefix }
        return "\(committedTranscriptPrefix) \(trimmedSegment)"
    }

    /// Appends a live audio buffer synchronously from `AVAudioEngine`'s tap thread before CoreAudio reuses it.
    nonisolated public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        activeRequestBox.append(buffer)
    }

    /// Ends audio input and cleans up the active recognition task.
    public func stop() {
        sessionGeneration &+= 1
        shouldRemainListening = false
        committedTranscriptPrefix = ""
        didReceiveTranscriptInCurrentTask = false
        usedOnDeviceFallback = false
        activeRequestBox.set(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    /// Normalizes multi-channel or non-Float32 hardware mic buffers to 1-channel Float32 PCM for `SFSpeechAudioBufferRecognitionRequest`.
    nonisolated public static func normalizeBufferForSpeech(
        _ buffer: AVAudioPCMBuffer,
        cachedConverter: inout AVAudioConverter?,
        cachedSourceFormat: inout AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let inputFormat = buffer.format
        if inputFormat.channelCount == 1 && inputFormat.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        guard let monoFloatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: max(8_000, inputFormat.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        if cachedConverter == nil || cachedSourceFormat != inputFormat {
            cachedConverter = AVAudioConverter(from: inputFormat, to: monoFloatFormat)
            cachedSourceFormat = inputFormat
        }

        if let converter = cachedConverter,
           let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFloatFormat, frameCapacity: buffer.frameCapacity) {
            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status != .error, conversionError == nil, outputBuffer.frameLength > 0 {
                return outputBuffer
            }
        }

        // Fallback for discrete multi-channel layouts (e.g. 3ch VPAUAggregateAudioDevice) where AVAudioConverter has no downmix matrix.
        if inputFormat.commonFormat == .pcmFormatFloat32,
           !inputFormat.isInterleaved,
           let srcChannels = buffer.floatChannelData,
           let fallbackBuffer = AVAudioPCMBuffer(pcmFormat: monoFloatFormat, frameCapacity: buffer.frameLength),
           let dstChannels = fallbackBuffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            memcpy(dstChannels[0], srcChannels[0], frameCount * MemoryLayout<Float>.size)
            fallbackBuffer.frameLength = buffer.frameLength
            return fallbackBuffer
        }

        return nil
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
