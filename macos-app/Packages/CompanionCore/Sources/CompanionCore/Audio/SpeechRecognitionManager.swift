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

    private static let maxConsecutiveRestartErrors = 5

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let activeRequestBox = ActiveRecognitionRequestBox()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var shouldRemainListening: Bool = false
    @ObservationIgnored private var committedTranscriptPrefix: String = ""
    @ObservationIgnored private var didReceiveTranscriptInCurrentTask: Bool = false
    @ObservationIgnored private var usedOnDeviceFallback: Bool = false
    @ObservationIgnored private var consecutiveErrorCount: Int = 0

    public init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    deinit {
        restartTask?.cancel()
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
        consecutiveErrorCount = 0
        beginRecognitionTask(
            using: recognizer,
            requireOnDevice: recognizer.supportsOnDeviceRecognition
        )
    }

    /// Clears accumulated transcripts and restarts the recognition request when actively listening.
    public func resetTranscript() {
        latestTranscript = ""
        committedTranscriptPrefix = ""
        didReceiveTranscriptInCurrentTask = false
        consecutiveErrorCount = 0

        if shouldRemainListening, let recognizer, recognizer.isAvailable {
            beginRecognitionTask(
                using: recognizer,
                requireOnDevice: recognizer.supportsOnDeviceRecognition && !usedOnDeviceFallback
            )
        }
    }

    private func beginRecognitionTask(using recognizer: SFSpeechRecognizer, requireOnDevice: Bool) {
        guard shouldRemainListening else { return }

        restartTask?.cancel()
        restartTask = nil
        sessionGeneration &+= 1
        let gen = sessionGeneration
        didReceiveTranscriptInCurrentTask = false

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        if requireOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        self.activeRequestBox.set(request)
        self.isListening = true

        self.recognitionTask = Self.startRecognitionTask(
            recognizer: recognizer,
            request: request
        ) { [weak self] transcript, isFinal, errorMessage, hasError, isRecoverableError in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == gen else { return }

                if let transcript, !transcript.isEmpty {
                    self.didReceiveTranscriptInCurrentTask = true
                    self.consecutiveErrorCount = 0
                    let combined = self.combinedTranscript(for: transcript)
                    self.latestTranscript = combined
                    self.onTranscriptUpdate?(combined, isFinal)
                } else if isFinal && !self.latestTranscript.isEmpty {
                    self.onTranscriptUpdate?(self.latestTranscript, true)
                }

                if hasError {
                    if requireOnDevice && !isRecoverableError && !self.didReceiveTranscriptInCurrentTask && !self.usedOnDeviceFallback && self.shouldRemainListening {
                        self.usedOnDeviceFallback = true
                        self.beginRecognitionTask(using: recognizer, requireOnDevice: false)
                        return
                    }

                    let isAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
                    let isAvailable = recognizer.isAvailable

                    if self.didReceiveTranscriptInCurrentTask {
                        self.committedTranscriptPrefix = self.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.consecutiveErrorCount = 0
                    } else if !isRecoverableError {
                        self.consecutiveErrorCount += 1
                    }

                    if self.shouldRemainListening,
                       isAuthorized,
                       isAvailable,
                       (isRecoverableError || self.consecutiveErrorCount <= Self.maxConsecutiveRestartErrors) {
                        let restartDelayMs = isRecoverableError ? 250 : 120
                        self.restartTask?.cancel()
                        self.restartTask = Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(restartDelayMs))
                            guard let self,
                                  !Task.isCancelled,
                                  self.sessionGeneration == gen,
                                  self.shouldRemainListening,
                                  SFSpeechRecognizer.authorizationStatus() == .authorized,
                                  let activeRecognizer = self.recognizer,
                                  activeRecognizer.isAvailable else {
                                return
                            }
                            self.beginRecognitionTask(
                                using: activeRecognizer,
                                requireOnDevice: activeRecognizer.supportsOnDeviceRecognition && !self.usedOnDeviceFallback
                            )
                        }
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
        restartTask?.cancel()
        restartTask = nil
        sessionGeneration &+= 1
        shouldRemainListening = false
        committedTranscriptPrefix = ""
        didReceiveTranscriptInCurrentTask = false
        usedOnDeviceFallback = false
        consecutiveErrorCount = 0
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

        // Extract active mono channel directly for discrete/multi-channel VoiceProcessingIO layouts
        // (e.g. 3ch VPAUAggregateAudioDevice) because AVAudioConverter silently zeroes unmapped discrete channels.
        let prefersDirectChannelExtraction = inputFormat.channelCount > 2 || isDiscreteChannelLayout(inputFormat)
        if prefersDirectChannelExtraction,
           let extracted = extractMonoFloat32Buffer(from: buffer, targetFormat: monoFloatFormat) {
            return extracted
        }

        if cachedConverter == nil || cachedSourceFormat != inputFormat {
            cachedConverter = AVAudioConverter(from: inputFormat, to: monoFloatFormat)
            cachedSourceFormat = inputFormat
        }

        let ratio = monoFloatFormat.sampleRate / max(1.0, inputFormat.sampleRate)
        let outputFrameCapacity = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16)
        if let converter = cachedConverter,
           let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFloatFormat, frameCapacity: outputFrameCapacity) {
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

        return extractMonoFloat32Buffer(from: buffer, targetFormat: monoFloatFormat)
    }

    nonisolated private static func isDiscreteChannelLayout(_ format: AVAudioFormat) -> Bool {
        guard format.channelCount > 1, let tag = format.channelLayout?.layoutTag else {
            return false
        }
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions || tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return true
        }
        return (tag & 0xFFFF_0000) == kAudioChannelLayoutTag_DiscreteInOrder
    }

    nonisolated private static func extractMonoFloat32Buffer(
        from buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              let fallbackBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameLength),
              let dstChannels = fallbackBuffer.floatChannelData else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(inputFormat.channelCount))

        if !inputFormat.isInterleaved, let srcChannels = buffer.floatChannelData {
            var selectedChannel = 0
            if channelCount > 1 {
                let firstChannelHasSignal = (0..<frameCount).contains { abs(srcChannels[0][$0]) > 1e-6 }
                if !firstChannelHasSignal {
                    for ch in 1..<channelCount {
                        if (0..<frameCount).contains(where: { abs(srcChannels[ch][$0]) > 1e-6 }) {
                            selectedChannel = ch
                            break
                        }
                    }
                }
            }
            memcpy(dstChannels[0], srcChannels[selectedChannel], frameCount * MemoryLayout<Float>.size)
            fallbackBuffer.frameLength = buffer.frameLength
            return fallbackBuffer
        }

        if inputFormat.isInterleaved {
            let mBuffer = buffer.audioBufferList.pointee.mBuffers
            if let rawPtr = mBuffer.mData {
                let samples = rawPtr.assumingMemoryBound(to: Float.self)
                let totalSamples = Int(mBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let availableFrames = min(frameCount, totalSamples / channelCount)
                guard availableFrames > 0 else { return nil }
                for frame in 0..<availableFrames {
                    dstChannels[0][frame] = samples[frame * channelCount]
                }
                fallbackBuffer.frameLength = AVAudioFrameCount(availableFrames)
                return fallbackBuffer
            }
        }

        return nil
    }

    nonisolated private static func isRecoverableRecognitionError(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else { return false }
        let desc = nsError.localizedDescription.lowercased()
        if desc.contains("denied") || desc.contains("restricted") || desc.contains("not authorized") || desc.contains("disabled") {
            return false
        }
        if nsError.domain == "kAFAssistantErrorDomain" && [1110, 203, 216, 1101, 1107].contains(nsError.code) {
            return true
        }
        if nsError.domain == "kLSRErrorDomain" && nsError.code == 301 {
            return true
        }
        return desc.contains("no speech") || desc.contains("retry") || desc.contains("cancel") || desc.contains("timed out")
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
        onEvent: @escaping @Sendable (String?, Bool, String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            let recoverable = Self.isRecoverableRecognitionError(error)
            onEvent(transcript, isFinal, errorMessage, error != nil, recoverable)
        }
    }
}
