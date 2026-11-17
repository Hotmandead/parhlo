@preconcurrency import AVFoundation
import Foundation
import Observation
import os

/// Errors raised by `AudioEngineManager` during audio graph configuration or conversion.
public enum AudioEngineError: Error, Sendable, Equatable {
    case unsupportedFormat
    case converterInitializationFailed
    case engineStartFailed(String)
}

/// Manages full-duplex 16 kHz microphone capture (with hardware AEC) and 24 kHz Gemini voice playback.
@MainActor
@Observable
public final class AudioEngineManager {
    nonisolated public static let upstreamSampleRate: Double = 16_000
    nonisolated public static let downstreamSampleRate: Double = 24_000
    nonisolated public static let channelCount: AVAudioChannelCount = 1

    public private(set) var isRunning: Bool = false
    public private(set) var isPlaybackRunning: Bool = false
    public private(set) var isVoiceProcessingActive: Bool = false
    public private(set) var isPlayingAudio: Bool = false
    public private(set) var isOutputMuted: Bool = false
    public private(set) var inputRMSLevel: Float = 0.0

    @ObservationIgnored public var voiceProcessingEnabled: Bool = true
    @ObservationIgnored public var localVADThreshold: Float = 0.065
    @ObservationIgnored public var localVADEnabled: Bool = true
    @ObservationIgnored public var consecutiveVADFramesRequired: Int = 3
    @ObservationIgnored public var postPlaybackHoldoffSeconds: TimeInterval = 0.35

    @ObservationIgnored public var onAudioChunk: (@Sendable (Data) -> Void)?
    @ObservationIgnored public var onRawAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    @ObservationIgnored public var onLocalVoiceActivity: (@Sendable () -> Void)?
    @ObservationIgnored public var onPlaybackStateChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored public var onSpeechEnergyDetected: (@MainActor (Float) -> Void)?
    @ObservationIgnored public var onError: (@Sendable (String) -> Void)?

    @ObservationIgnored private let worker = AudioGraphWorker()
    @ObservationIgnored internal let playbackTapGate = PlaybackTapGate()
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var playbackToken: UInt64 = 0
    @ObservationIgnored private var lastLocalVADTrigger: Date = .distantPast

    public init() {}

    /// Starts full-duplex `AVAudioEngine` capture (16 kHz Int16 PCM) and playback (24 kHz Int16 PCM).
    public func start() throws {
        guard !isRunning else { return }
        if isPlaybackRunning {
            stop()
        }

        guard let downSourceFormat = Self.makePCMInt16Format(sampleRate: Self.downstreamSampleRate),
              let upTargetFormat = Self.makePCMInt16Format(sampleRate: Self.upstreamSampleRate) else {
            throw AudioEngineError.unsupportedFormat
        }

        let voiceProcessing = voiceProcessingEnabled
        let chunkCallback = onAudioChunk
        let rawBufferCallback = onRawAudioBuffer
        let vadThreshold = localVADThreshold
        let vadEnabled = localVADEnabled
        let framesRequired = max(1, consecutiveVADFramesRequired)
        let rmsGate = RMSThrottleGate(minIntervalNanoseconds: 40_000_000)

        sessionGeneration &+= 1
        let gen = sessionGeneration
        isRunning = true
        isPlaybackRunning = true
        isVoiceProcessingActive = false
        playbackTapGate.setVoiceProcessingActive(false)
        playbackTapGate.resetHoldoff()

        worker.startCaptureAndPlayback(
            voiceProcessingEnabled: voiceProcessing,
            downSourceFormat: downSourceFormat,
            upTargetFormat: upTargetFormat,
            chunkCallback: chunkCallback,
            rawBufferCallback: rawBufferCallback,
            playbackTapGate: playbackTapGate,
            vadEnabled: vadEnabled,
            vadThreshold: vadThreshold,
            framesRequired: framesRequired,
            onBargeInTriggered: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    guard vadEnabled && self.isVoiceProcessingActive && self.isPlayingAudio else { return }
                    let now = Date()
                    if now.timeIntervalSince(self.lastLocalVADTrigger) >= 0.4 {
                        self.lastLocalVADTrigger = now
                        self.onLocalVoiceActivity?()
                    }
                }
            },
            onRMS: { [weak self] rms in
                guard rms >= vadThreshold || rmsGate.shouldEmit() else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    self.inputRMSLevel = rms
                    if rms >= vadThreshold && !self.isPlayingAudio {
                        self.onSpeechEnergyDetected?(rms)
                    }
                }
            },
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    switch event {
                    case .started(let voiceProcessingActive):
                        self.isVoiceProcessingActive = voiceProcessingActive
                        self.playbackTapGate.setVoiceProcessingActive(voiceProcessingActive)
                    case .fellBackToStandardCapture:
                        self.playbackToken &+= 1
                        self.setPlayingState(false, applyHoldoff: false)
                        self.isVoiceProcessingActive = false
                        self.playbackTapGate.setVoiceProcessingActive(false)
                    case .failed(let message):
                        self.playbackToken &+= 1
                        self.setPlayingState(false, applyHoldoff: false)
                        self.isRunning = false
                        self.isPlaybackRunning = false
                        self.isVoiceProcessingActive = false
                        self.playbackTapGate.setVoiceProcessingActive(false)
                        self.inputRMSLevel = 0
                        self.onError?(message)
                    }
                }
            }
        )
    }

    /// Stops audio capture and playback and tears down the `AVAudioEngine` graph.
    public func stop() {
        guard isRunning || isPlaybackRunning else { return }

        sessionGeneration &+= 1
        playbackToken &+= 1
        setPlayingState(false, applyHoldoff: false)
        isVoiceProcessingActive = false
        playbackTapGate.setVoiceProcessingActive(false)
        inputRMSLevel = 0
        isRunning = false
        isPlaybackRunning = false

        worker.stop()
    }

    /// Mutes or unmutes downstream 24 kHz voice playback, flushing queued audio immediately when muting.
    public func setOutputMuted(_ muted: Bool) {
        isOutputMuted = muted
        if muted {
            stopPlaybackImmediately()
        }
    }

    /// Schedules a downstream 24 kHz 16-bit mono PCM chunk for low-latency playback.
    public func enqueuePlayback(pcm24kData: Data) {
        guard !isOutputMuted, !pcm24kData.isEmpty else { return }
        guard let downSourceFormat = Self.makePCMInt16Format(sampleRate: Self.downstreamSampleRate) else {
            return
        }

        if !isRunning && !isPlaybackRunning {
            isPlaybackRunning = true
        }

        let gen = sessionGeneration
        playbackToken &+= 1
        let token = playbackToken
        setPlayingState(true, applyHoldoff: false)

        worker.enqueuePlayback(
            pcm24kData: pcm24kData,
            token: token,
            downSourceFormat: downSourceFormat,
            onPlaybackStateChanged: { [weak self] isPlaying, completedToken in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.sessionGeneration == gen,
                          self.playbackToken == completedToken else {
                        return
                    }
                    self.setPlayingState(isPlaying, applyHoldoff: !isPlaying)
                }
            },
            onPlaybackStartFailed: { [weak self] errorMessage, failedToken in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    if !self.isRunning {
                        self.isPlaybackRunning = false
                    }
                    if self.playbackToken == failedToken {
                        self.setPlayingState(false, applyHoldoff: false)
                    }
                    self.onError?(errorMessage)
                }
            }
        )
    }

    /// Immediately flushes queued playback buffers on VAD or manual barge-in.
    public func stopPlaybackImmediately() {
        playbackToken &+= 1
        setPlayingState(false, applyHoldoff: false)
        worker.stopPlaybackImmediately()
    }

    internal func setPlayingStateForTesting(_ playing: Bool) {
        setPlayingState(playing, applyHoldoff: false)
    }

    private func setPlayingState(_ playing: Bool, applyHoldoff: Bool) {
        let changed = isPlayingAudio != playing
        isPlayingAudio = playing
        playbackTapGate.setPlaying(playing, holdoffSeconds: applyHoldoff ? postPlaybackHoldoffSeconds : 0)
        if changed {
            onPlaybackStateChanged?(playing)
        }
    }

    // MARK: - Nonisolated Audio Thread Bridges

    // Keep AVFoundation callbacks off @MainActor so Swift 6 does not insert main-queue assertions on audio threads.
    nonisolated fileprivate static func installInputTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        upConverter: AVAudioConverter,
        upTargetFormat: AVAudioFormat,
        chunkCallback: (@Sendable (Data) -> Void)?,
        rawBufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        playbackTapGate: PlaybackTapGate,
        vadEnabled: Bool,
        vadThreshold: Float,
        framesRequired: Int,
        onBargeInTriggered: @escaping @Sendable () -> Void,
        onBufferDelivered: @escaping @Sendable () -> Void,
        onRMS: @escaping @Sendable (Float) -> Void
    ) {
        let monoConverterCache = MonoConverterCache()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let pcmData = convertToPCMInt16Data(
                buffer: buffer,
                converter: upConverter,
                targetFormat: upTargetFormat,
                monoConverterCache: monoConverterCache
            ), !pcmData.isEmpty else {
                return
            }

            onBufferDelivered()
            let rms = computePCM16RMS(pcmData)
            let decision = playbackTapGate.evaluate(
                rms: rms,
                vadEnabled: vadEnabled,
                vadThreshold: vadThreshold,
                framesRequired: framesRequired
            )
            if decision.triggeredBargeIn {
                onBargeInTriggered()
            }
            if decision.forwardRawBuffer {
                rawBufferCallback?(buffer)
            }
            chunkCallback?(pcmData)
            onRMS(rms)
        }
    }

    nonisolated fileprivate static func schedulePlaybackBuffer(
        _ buffer: AVAudioPCMBuffer,
        on playerNode: AVAudioPlayerNode,
        onComplete: @escaping @Sendable () -> Void
    ) {
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            onComplete()
        }
    }

    // MARK: - Pure Testable Audio Conversion Helpers

    nonisolated public static func makePCMInt16Format(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        )
    }

    nonisolated public static func convertToPCMInt16Data(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        convertToPCMInt16Data(
            buffer: buffer,
            converter: converter,
            targetFormat: targetFormat,
            monoConverterCache: nil
        )
    }

    nonisolated fileprivate static func convertToPCMInt16Data(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        monoConverterCache: MonoConverterCache?
    ) -> Data? {
        guard buffer.frameLength > 0 else { return nil }

        let inputFormat = buffer.format
        let prefersChannel0Extraction = inputFormat.channelCount > 2 || isDiscreteOrUnspecifiedLayout(inputFormat)

        if !prefersChannel0Extraction,
           let direct = convertSingleBufferToPCMInt16Data(
               buffer: buffer,
               converter: converter,
               targetFormat: targetFormat
           ) {
            return direct
        }

        // Extract channel 0 directly for discrete / multi-channel hardware & VoiceProcessingIO
        // layouts (e.g. 3ch VPAUAggregateAudioDevice) where AVAudioConverter either has no downmix
        // matrix or silently zeroes unmapped discrete channels.
        if let monoConverted = convertChannel0Float32ToPCMInt16Data(
            buffer: buffer,
            targetFormat: targetFormat,
            monoConverterCache: monoConverterCache
        ) {
            return monoConverted
        }

        guard prefersChannel0Extraction else {
            return nil
        }

        return convertSingleBufferToPCMInt16Data(
            buffer: buffer,
            converter: converter,
            targetFormat: targetFormat
        )
    }

    nonisolated private static func isDiscreteOrUnspecifiedLayout(_ format: AVAudioFormat) -> Bool {
        guard format.channelCount > 1 else { return false }
        guard let tag = format.channelLayout?.layoutTag else {
            return true
        }
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions || tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return true
        }
        return (tag & 0xFFFF_0000) == kAudioChannelLayoutTag_DiscreteInOrder
    }

    nonisolated private static func convertChannel0Float32ToPCMInt16Data(
        buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        monoConverterCache: MonoConverterCache?
    ) -> Data? {
        let inputFormat = buffer.format
        guard inputFormat.channelCount > 1,
              inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved,
              let srcChannels = buffer.floatChannelData,
              let monoFloatFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: max(1.0, inputFormat.sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFloatFormat, frameCapacity: buffer.frameLength),
              let dstChannels = monoBuffer.floatChannelData else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        memcpy(dstChannels[0], srcChannels[0], frameCount * MemoryLayout<Float>.size)
        monoBuffer.frameLength = buffer.frameLength

        return monoConverterCache?.convert(monoBuffer: monoBuffer, sourceFormat: monoFloatFormat, targetFormat: targetFormat)
            ?? AVAudioConverter(from: monoFloatFormat, to: targetFormat).flatMap {
                convertSingleBufferToPCMInt16Data(
                    buffer: monoBuffer,
                    converter: $0,
                    targetFormat: targetFormat
                )
            }
    }

    nonisolated fileprivate static func makeMonoFallbackConverter(
        from inputFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) -> AVAudioConverter? {
        guard inputFormat.channelCount > 1,
              inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved,
              let monoFloatFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: max(1.0, inputFormat.sampleRate),
                  channels: 1,
                  interleaved: false
              ) else {
            return nil
        }
        return AVAudioConverter(from: monoFloatFormat, to: targetFormat)
    }

    nonisolated fileprivate static func convertSingleBufferToPCMInt16Data(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        let ratio = targetFormat.sampleRate / max(1.0, buffer.format.sampleRate)
        let estimatedFrames = max(1, AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            return nil
        }

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

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return nil
        }
        return Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
    }

    nonisolated public static func convertPCM24kInt16ToPlaybackBuffer(
        pcmData: Data,
        sourceFormat: AVAudioFormat,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, pcmData.count >= bytesPerFrame else { return nil }

        let frameCount = AVAudioFrameCount(pcmData.count / bytesPerFrame)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }
        inputBuffer.frameLength = frameCount

        let dst = inputBuffer.audioBufferList.pointee.mBuffers
        guard let dstPtr = dst.mData else { return nil }
        let copyByteCount = min(Int(dst.mDataByteSize), pcmData.count)
        pcmData.withUnsafeBytes { rawBytes in
            if let base = rawBytes.baseAddress {
                memcpy(dstPtr, base, copyByteCount)
            }
        }

        let ratio = targetFormat.sampleRate / max(1.0, sourceFormat.sampleRate)
        let outCapacity = max(1, AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }

    nonisolated public static func computePCM16RMS(_ pcmData: Data) -> Float {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        var sumSquares: Double = 0
        pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for sample in samples {
                let normalized = Double(sample) / Double(Int16.max)
                sumSquares += normalized * normalized
            }
        }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }
}

private enum CaptureGraphEvent: Sendable {
    case started(voiceProcessingActive: Bool)
    case fellBackToStandardCapture
    case failed(String)
}

private final class TapDeliveryFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)

    func markDelivered() {
        lock.withLock { delivered in
            if !delivered {
                delivered = true
            }
        }
    }

    var hasDelivered: Bool {
        lock.withLock { $0 }
    }
}

private final class MonoConverterCache: @unchecked Sendable {
    private struct State {
        var sourceFormat: AVAudioFormat?
        var targetFormat: AVAudioFormat?
        var converter: AVAudioConverter?
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func convert(
        monoBuffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> Data? {
        lock.withLock { state in
            let activeConverter: AVAudioConverter?
            if let existing = state.converter,
               state.sourceFormat == sourceFormat,
               state.targetFormat == targetFormat {
                activeConverter = existing
            } else {
                let created = AVAudioConverter(from: sourceFormat, to: targetFormat)
                state.sourceFormat = sourceFormat
                state.targetFormat = targetFormat
                state.converter = created
                activeConverter = created
            }

            guard let activeConverter else { return nil }
            return AudioEngineManager.convertSingleBufferToPCMInt16Data(
                buffer: monoBuffer,
                converter: activeConverter,
                targetFormat: targetFormat
            )
        }
    }
}

internal struct PlaybackTapDecision: Sendable, Equatable {
    let forwardRawBuffer: Bool
    let triggeredBargeIn: Bool
}

internal final class PlaybackTapGate: @unchecked Sendable {
    private struct State {
        var isPlaying: Bool = false
        var voiceProcessingActive: Bool = false
        var holdoffUntilNanoseconds: UInt64 = 0
        var consecutiveVADFrames: Int = 0
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func setVoiceProcessingActive(_ active: Bool) {
        lock.withLock { state in
            state.voiceProcessingActive = active
            if !active {
                state.consecutiveVADFrames = 0
            }
        }
    }

    func resetHoldoff() {
        lock.withLock { state in
            state.holdoffUntilNanoseconds = 0
            state.consecutiveVADFrames = 0
        }
    }

    func setPlaying(_ playing: Bool, holdoffSeconds: TimeInterval = 0) {
        let now = DispatchTime.now().uptimeNanoseconds
        let holdoffNs = holdoffSeconds > 0 ? UInt64(holdoffSeconds * 1_000_000_000) : 0
        lock.withLock { state in
            state.isPlaying = playing
            state.consecutiveVADFrames = 0
            if playing {
                state.holdoffUntilNanoseconds = 0
            } else if holdoffNs > 0 {
                state.holdoffUntilNanoseconds = now &+ holdoffNs
            }
        }
    }

    func evaluate(
        rms: Float,
        vadEnabled: Bool,
        vadThreshold: Float,
        framesRequired: Int,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> PlaybackTapDecision {
        lock.withLock { state in
            if state.isPlaying {
                guard vadEnabled, state.voiceProcessingActive else {
                    state.consecutiveVADFrames = 0
                    return PlaybackTapDecision(forwardRawBuffer: false, triggeredBargeIn: false)
                }
                if rms >= vadThreshold {
                    state.consecutiveVADFrames += 1
                    if state.consecutiveVADFrames >= max(1, framesRequired) {
                        state.isPlaying = false
                        state.holdoffUntilNanoseconds = 0
                        state.consecutiveVADFrames = 0
                        return PlaybackTapDecision(forwardRawBuffer: true, triggeredBargeIn: true)
                    }
                } else {
                    state.consecutiveVADFrames = 0
                }
                return PlaybackTapDecision(forwardRawBuffer: false, triggeredBargeIn: false)
            }

            if state.holdoffUntilNanoseconds > 0 && nowNanoseconds < state.holdoffUntilNanoseconds {
                return PlaybackTapDecision(forwardRawBuffer: false, triggeredBargeIn: false)
            }
            state.holdoffUntilNanoseconds = 0
            return PlaybackTapDecision(forwardRawBuffer: true, triggeredBargeIn: false)
        }
    }
}

private final class RMSThrottleGate: @unchecked Sendable {
    private let minIntervalNanoseconds: UInt64
    private let lock = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    init(minIntervalNanoseconds: UInt64) {
        self.minIntervalNanoseconds = minIntervalNanoseconds
    }

    func shouldEmit() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock { last in
            if last == 0 || now &- last >= minIntervalNanoseconds {
                last = now
                return true
            }
            return false
        }
    }
}

/// Owns `AVAudioEngine` lifecycle and audio graph operations on a dedicated Default-QoS serial queue
/// so `@MainActor` (`User-interactive`) never blocks on CoreAudio's `Default`-QoS internal threads.
private final class AudioGraphWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.parhlo.audio-engine", qos: .default)

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackConverter: AVAudioConverter?
    private var playbackSourceFormat: AVAudioFormat?
    private var playbackTargetFormat: AVAudioFormat?
    private var isCapturing: Bool = false
    private var isPlaybackActive: Bool = false
    private var activeScheduledBuffers: Int = 0
    private var playbackGeneration: UInt64 = 0
    private var latestPlaybackToken: UInt64 = 0
    private var captureGeneration: UInt64 = 0

    deinit {
        let engine = self.engine
        let playerNode = self.playerNode
        let isCapturing = self.isCapturing
        if engine != nil || playerNode != nil {
            queue.async {
                if isCapturing {
                    engine?.inputNode.removeTap(onBus: 0)
                }
                playerNode?.stop()
                engine?.stop()
                engine?.reset()
            }
        }
    }

    func startCaptureAndPlayback(
        voiceProcessingEnabled: Bool,
        downSourceFormat: AVAudioFormat,
        upTargetFormat: AVAudioFormat,
        chunkCallback: (@Sendable (Data) -> Void)?,
        rawBufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        playbackTapGate: PlaybackTapGate,
        vadEnabled: Bool,
        vadThreshold: Float,
        framesRequired: Int,
        onBargeInTriggered: @escaping @Sendable () -> Void,
        onRMS: @escaping @Sendable (Float) -> Void,
        onEvent: @escaping @Sendable (CaptureGraphEvent) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.isCapturing || self.isPlaybackActive {
                    self.teardownOnQueue()
                }
                let voiceProcessingActive = try self.startCaptureAndPlaybackOnQueue(
                    voiceProcessingEnabled: voiceProcessingEnabled,
                    downSourceFormat: downSourceFormat,
                    upTargetFormat: upTargetFormat,
                    chunkCallback: chunkCallback,
                    rawBufferCallback: rawBufferCallback,
                    playbackTapGate: playbackTapGate,
                    vadEnabled: vadEnabled,
                    vadThreshold: vadThreshold,
                    framesRequired: framesRequired,
                    onBargeInTriggered: onBargeInTriggered,
                    onRMS: onRMS,
                    onEvent: onEvent
                )
                onEvent(.started(voiceProcessingActive: voiceProcessingActive))
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    private func startCaptureAndPlaybackOnQueue(
        voiceProcessingEnabled: Bool,
        downSourceFormat: AVAudioFormat,
        upTargetFormat: AVAudioFormat,
        chunkCallback: (@Sendable (Data) -> Void)?,
        rawBufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        playbackTapGate: PlaybackTapGate,
        vadEnabled: Bool,
        vadThreshold: Float,
        framesRequired: Int,
        onBargeInTriggered: @escaping @Sendable () -> Void,
        onRMS: @escaping @Sendable (Float) -> Void,
        onEvent: @escaping @Sendable (CaptureGraphEvent) -> Void
    ) throws -> Bool {
        let audioEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var didInstallTap = false

        do {
            // Configure voice processing on inputNode before touching mainMixerNode/outputNode
            // so CoreAudio builds its aggregate device cleanly without -10877 / 2003332927.
            let voiceProcessingActive: Bool
            if voiceProcessingEnabled {
                try audioEngine.inputNode.setVoiceProcessingEnabled(true)
                audioEngine.inputNode.isVoiceProcessingBypassed = false
                audioEngine.inputNode.isVoiceProcessingAGCEnabled = true
                voiceProcessingActive = true
            } else {
                voiceProcessingActive = false
            }

            audioEngine.attach(player)
            let mainMixer = audioEngine.mainMixerNode
            let mixerFormat = mainMixer.outputFormat(forBus: 0)
            audioEngine.connect(player, to: mainMixer, format: mixerFormat)

            guard let downConverter = AVAudioConverter(from: downSourceFormat, to: mixerFormat) else {
                throw AudioEngineError.converterInitializationFailed
            }

            let inputNode = audioEngine.inputNode
            let hardwareInputFormat = inputNode.outputFormat(forBus: 0)
            guard hardwareInputFormat.sampleRate > 0, hardwareInputFormat.channelCount > 0 else {
                throw AudioEngineError.unsupportedFormat
            }
            guard let upConverter = AVAudioConverter(from: hardwareInputFormat, to: upTargetFormat)
                ?? AudioEngineManager.makeMonoFallbackConverter(from: hardwareInputFormat, to: upTargetFormat) else {
                throw AudioEngineError.converterInitializationFailed
            }

            let tapFlag = TapDeliveryFlag()
            inputNode.removeTap(onBus: 0)
            AudioEngineManager.installInputTap(
                on: inputNode,
                format: hardwareInputFormat,
                upConverter: upConverter,
                upTargetFormat: upTargetFormat,
                chunkCallback: chunkCallback,
                rawBufferCallback: rawBufferCallback,
                playbackTapGate: playbackTapGate,
                vadEnabled: vadEnabled,
                vadThreshold: vadThreshold,
                framesRequired: framesRequired,
                onBargeInTriggered: onBargeInTriggered,
                onBufferDelivered: {
                    tapFlag.markDelivered()
                },
                onRMS: onRMS
            )
            didInstallTap = true

            audioEngine.prepare()
            try audioEngine.start()
            player.play()

            captureGeneration &+= 1
            let activeCaptureGen = captureGeneration
            self.engine = audioEngine
            self.playerNode = player
            self.playbackConverter = downConverter
            self.playbackSourceFormat = downSourceFormat
            self.playbackTargetFormat = mixerFormat
            self.activeScheduledBuffers = 0
            self.isCapturing = true
            self.isPlaybackActive = true

            // Watchdog: AUVoiceProcessor on macOS can return from start() without throwing while HAL StartIO
            // fails with error 35 / -10877 and delivers zero tap buffers. Fall back to non-VP capture automatically.
            let watchdogDelay: DispatchTimeInterval = voiceProcessingActive ? .milliseconds(1400) : .milliseconds(1500)
            queue.asyncAfter(deadline: .now() + watchdogDelay) { [weak self] in
                guard let self,
                      self.isCapturing,
                      self.captureGeneration == activeCaptureGen,
                      !tapFlag.hasDelivered else {
                    return
                }

                if voiceProcessingActive {
                    self.teardownOnQueue()
                    do {
                        _ = try self.startCaptureAndPlaybackOnQueue(
                            voiceProcessingEnabled: false,
                            downSourceFormat: downSourceFormat,
                            upTargetFormat: upTargetFormat,
                            chunkCallback: chunkCallback,
                            rawBufferCallback: rawBufferCallback,
                            playbackTapGate: playbackTapGate,
                            vadEnabled: vadEnabled,
                            vadThreshold: vadThreshold,
                            framesRequired: framesRequired,
                            onBargeInTriggered: onBargeInTriggered,
                            onRMS: onRMS,
                            onEvent: onEvent
                        )
                        onEvent(.fellBackToStandardCapture)
                    } catch {
                        onEvent(.failed(error.localizedDescription))
                    }
                } else {
                    self.teardownOnQueue()
                    onEvent(.failed("Microphone audio input did not start (no audio buffers received from hardware)."))
                }
            }

            return voiceProcessingActive
        } catch {
            if didInstallTap {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            player.stop()
            audioEngine.stop()
            audioEngine.reset()

            if voiceProcessingEnabled {
                return try startCaptureAndPlaybackOnQueue(
                    voiceProcessingEnabled: false,
                    downSourceFormat: downSourceFormat,
                    upTargetFormat: upTargetFormat,
                    chunkCallback: chunkCallback,
                    rawBufferCallback: rawBufferCallback,
                    playbackTapGate: playbackTapGate,
                    vadEnabled: vadEnabled,
                    vadThreshold: vadThreshold,
                    framesRequired: framesRequired,
                    onBargeInTriggered: onBargeInTriggered,
                    onRMS: onRMS,
                    onEvent: onEvent
                )
            }

            throw error
        }
    }

    func enqueuePlayback(
        pcm24kData: Data,
        token: UInt64,
        downSourceFormat: AVAudioFormat,
        onPlaybackStateChanged: @escaping @Sendable (Bool, UInt64) -> Void,
        onPlaybackStartFailed: @escaping @Sendable (String, UInt64) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestPlaybackToken = token

            if !self.isCapturing && !self.isPlaybackActive {
                do {
                    try self.startPlaybackOnlyOnQueueIfNeeded(downSourceFormat: downSourceFormat)
                } catch {
                    onPlaybackStartFailed(error.localizedDescription, token)
                    return
                }
            }

            guard self.isCapturing || self.isPlaybackActive,
                  let playerNode = self.playerNode,
                  let playbackConverter = self.playbackConverter,
                  let playbackSourceFormat = self.playbackSourceFormat,
                  let playbackTargetFormat = self.playbackTargetFormat else {
                if self.activeScheduledBuffers == 0 {
                    onPlaybackStateChanged(false, self.latestPlaybackToken)
                }
                return
            }

            guard let floatBuffer = AudioEngineManager.convertPCM24kInt16ToPlaybackBuffer(
                pcmData: pcm24kData,
                sourceFormat: playbackSourceFormat,
                converter: playbackConverter,
                targetFormat: playbackTargetFormat
            ) else {
                if self.activeScheduledBuffers == 0 {
                    onPlaybackStateChanged(false, self.latestPlaybackToken)
                }
                return
            }

            let generation = self.playbackGeneration
            self.activeScheduledBuffers += 1
            if !playerNode.isPlaying {
                playerNode.play()
            }

            AudioEngineManager.schedulePlaybackBuffer(floatBuffer, on: playerNode) { [weak self] in
                self?.handleScheduledBufferCompletion(
                    generation: generation,
                    onPlaybackStateChanged: onPlaybackStateChanged
                )
            }
        }
    }

    func stopPlaybackImmediately() {
        queue.async { [weak self] in
            guard let self else { return }
            self.playbackGeneration &+= 1
            self.activeScheduledBuffers = 0
            guard let playerNode = self.playerNode else { return }
            playerNode.stop()
            if self.isCapturing || self.isPlaybackActive {
                playerNode.play()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardownOnQueue()
        }
    }

    private func startPlaybackOnlyOnQueueIfNeeded(downSourceFormat: AVAudioFormat) throws {
        guard !isCapturing && !isPlaybackActive else { return }

        let audioEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        audioEngine.attach(player)

        let mainMixer = audioEngine.mainMixerNode
        let mixerFormat = mainMixer.outputFormat(forBus: 0)
        audioEngine.connect(player, to: mainMixer, format: mixerFormat)

        guard let downConverter = AVAudioConverter(from: downSourceFormat, to: mixerFormat) else {
            throw AudioEngineError.converterInitializationFailed
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            player.play()
        } catch {
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }

        self.engine = audioEngine
        self.playerNode = player
        self.playbackConverter = downConverter
        self.playbackSourceFormat = downSourceFormat
        self.playbackTargetFormat = mixerFormat
        self.activeScheduledBuffers = 0
        self.isPlaybackActive = true
    }

    private func handleScheduledBufferCompletion(
        generation: UInt64,
        onPlaybackStateChanged: @escaping @Sendable (Bool, UInt64) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.activeScheduledBuffers = max(0, self.activeScheduledBuffers - 1)
            if self.activeScheduledBuffers == 0 {
                onPlaybackStateChanged(false, self.latestPlaybackToken)
            }
        }
    }

    private func teardownOnQueue() {
        captureGeneration &+= 1
        playbackGeneration &+= 1
        if let engine {
            if isCapturing {
                engine.inputNode.removeTap(onBus: 0)
            }
            playerNode?.stop()
            engine.stop()
            engine.reset()
        }

        engine = nil
        playerNode = nil
        playbackConverter = nil
        playbackSourceFormat = nil
        playbackTargetFormat = nil
        activeScheduledBuffers = 0
        isCapturing = false
        isPlaybackActive = false
    }
}
