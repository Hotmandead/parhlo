@preconcurrency import AVFoundation
import Foundation
import Observation

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
    @ObservationIgnored public var localVADThreshold: Float = 0.025
    @ObservationIgnored public var localVADEnabled: Bool = true

    @ObservationIgnored public var onAudioChunk: (@Sendable (Data) -> Void)?
    @ObservationIgnored public var onRawAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    @ObservationIgnored public var onLocalVoiceActivity: (@Sendable () -> Void)?
    @ObservationIgnored public var onError: (@Sendable (String) -> Void)?

    @ObservationIgnored private let worker = AudioGraphWorker()
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

        sessionGeneration &+= 1
        let gen = sessionGeneration
        isRunning = true
        isPlaybackRunning = true
        isVoiceProcessingActive = false

        worker.startCaptureAndPlayback(
            voiceProcessingEnabled: voiceProcessing,
            downSourceFormat: downSourceFormat,
            upTargetFormat: upTargetFormat,
            chunkCallback: chunkCallback,
            rawBufferCallback: rawBufferCallback,
            onRMS: { [weak self] rms in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    self.inputRMSLevel = rms
                    if vadEnabled && self.isPlayingAudio && rms >= vadThreshold {
                        let now = Date()
                        if now.timeIntervalSince(self.lastLocalVADTrigger) >= 0.4 {
                            self.lastLocalVADTrigger = now
                            self.onLocalVoiceActivity?()
                        }
                    }
                }
            },
            onFinished: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    switch result {
                    case .success(let voiceProcessingActive):
                        self.isVoiceProcessingActive = voiceProcessingActive
                    case .failure(let error):
                        self.isRunning = false
                        self.isPlaybackRunning = false
                        self.isVoiceProcessingActive = false
                        self.onError?(error.localizedDescription)
                    }
                }
            }
        )
    }

    /// Starts playback-only `AVAudioEngine` output so typed prompts can speak responses without opening the mic.
    public func startPlaybackOnlyIfNeeded() throws {
        guard !isRunning && !isPlaybackRunning else { return }

        guard let downSourceFormat = Self.makePCMInt16Format(sampleRate: Self.downstreamSampleRate) else {
            throw AudioEngineError.unsupportedFormat
        }

        let gen = sessionGeneration
        isPlaybackRunning = true

        worker.startPlaybackOnlyIfNeeded(downSourceFormat: downSourceFormat) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == gen else { return }
                self.isPlaybackRunning = false
                self.onError?(error.localizedDescription)
            }
        }
    }

    /// Stops audio capture and playback and tears down the `AVAudioEngine` graph.
    public func stop() {
        guard isRunning || isPlaybackRunning else { return }

        sessionGeneration &+= 1
        playbackToken &+= 1
        isPlayingAudio = false
        isVoiceProcessingActive = false
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
        let token = playbackToken
        isPlayingAudio = true

        worker.enqueuePlayback(
            pcm24kData: pcm24kData,
            downSourceFormat: downSourceFormat,
            onPlaybackStateChanged: { [weak self] isPlaying in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.sessionGeneration == gen,
                          self.playbackToken == token else {
                        return
                    }
                    self.isPlayingAudio = isPlaying
                }
            },
            onPlaybackStartFailed: { [weak self] errorMessage in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == gen else { return }
                    if !self.isRunning {
                        self.isPlaybackRunning = false
                    }
                    self.isPlayingAudio = false
                    self.onError?(errorMessage)
                }
            }
        )
    }

    /// Immediately flushes queued playback buffers on VAD or manual barge-in.
    public func stopPlaybackImmediately() {
        playbackToken &+= 1
        isPlayingAudio = false
        worker.stopPlaybackImmediately()
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
        onRMS: @escaping @Sendable (Float) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            rawBufferCallback?(buffer)

            guard let pcmData = convertToPCMInt16Data(
                buffer: buffer,
                converter: upConverter,
                targetFormat: upTargetFormat
            ) else {
                return
            }

            let rms = computePCM16RMS(pcmData)
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
        guard buffer.frameLength > 0 else { return nil }

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
            }
        }
    }

    func startCaptureAndPlayback(
        voiceProcessingEnabled: Bool,
        downSourceFormat: AVAudioFormat,
        upTargetFormat: AVAudioFormat,
        chunkCallback: (@Sendable (Data) -> Void)?,
        rawBufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onRMS: @escaping @Sendable (Float) -> Void,
        onFinished: @escaping @Sendable (Result<Bool, any Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.isCapturing || self.isPlaybackActive {
                    self.teardownOnQueue()
                }

                let audioEngine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                audioEngine.attach(player)

                let inputNode = audioEngine.inputNode
                let voiceProcessingActive: Bool
                if voiceProcessingEnabled {
                    do {
                        try inputNode.setVoiceProcessingEnabled(true)
                        voiceProcessingActive = true
                    } catch {
                        // Keep running if hardware/virtual device rejects voice processing.
                        voiceProcessingActive = false
                    }
                } else {
                    voiceProcessingActive = false
                }

                let mainMixer = audioEngine.mainMixerNode
                let mixerFormat = mainMixer.outputFormat(forBus: 0)
                audioEngine.connect(player, to: mainMixer, format: mixerFormat)

                guard let downConverter = AVAudioConverter(from: downSourceFormat, to: mixerFormat) else {
                    throw AudioEngineError.converterInitializationFailed
                }

                let hardwareInputFormat = inputNode.outputFormat(forBus: 0)
                guard hardwareInputFormat.sampleRate > 0, hardwareInputFormat.channelCount > 0 else {
                    throw AudioEngineError.unsupportedFormat
                }
                guard let upConverter = AVAudioConverter(from: hardwareInputFormat, to: upTargetFormat) else {
                    throw AudioEngineError.converterInitializationFailed
                }

                inputNode.removeTap(onBus: 0)
                AudioEngineManager.installInputTap(
                    on: inputNode,
                    format: hardwareInputFormat,
                    upConverter: upConverter,
                    upTargetFormat: upTargetFormat,
                    chunkCallback: chunkCallback,
                    rawBufferCallback: rawBufferCallback,
                    onRMS: onRMS
                )

                do {
                    audioEngine.prepare()
                    try audioEngine.start()
                    player.play()
                } catch {
                    inputNode.removeTap(onBus: 0)
                    throw AudioEngineError.engineStartFailed(error.localizedDescription)
                }

                self.engine = audioEngine
                self.playerNode = player
                self.playbackConverter = downConverter
                self.playbackSourceFormat = downSourceFormat
                self.playbackTargetFormat = mixerFormat
                self.activeScheduledBuffers = 0
                self.isCapturing = true
                self.isPlaybackActive = true

                onFinished(.success(voiceProcessingActive))
            } catch {
                onFinished(.failure(error))
            }
        }
    }

    func startPlaybackOnlyIfNeeded(
        downSourceFormat: AVAudioFormat,
        onFinished: @escaping @Sendable ((any Error)?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.startPlaybackOnlyOnQueueIfNeeded(downSourceFormat: downSourceFormat)
                onFinished(nil)
            } catch {
                onFinished(error)
            }
        }
    }

    func enqueuePlayback(
        pcm24kData: Data,
        downSourceFormat: AVAudioFormat,
        onPlaybackStateChanged: @escaping @Sendable (Bool) -> Void,
        onPlaybackStartFailed: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isCapturing && !self.isPlaybackActive {
                do {
                    try self.startPlaybackOnlyOnQueueIfNeeded(downSourceFormat: downSourceFormat)
                } catch {
                    onPlaybackStartFailed(error.localizedDescription)
                    return
                }
            }

            guard self.isCapturing || self.isPlaybackActive,
                  let playerNode = self.playerNode,
                  let playbackConverter = self.playbackConverter,
                  let playbackSourceFormat = self.playbackSourceFormat,
                  let playbackTargetFormat = self.playbackTargetFormat else {
                if self.activeScheduledBuffers == 0 {
                    onPlaybackStateChanged(false)
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
                    onPlaybackStateChanged(false)
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
        onPlaybackStateChanged: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.activeScheduledBuffers = max(0, self.activeScheduledBuffers - 1)
            if self.activeScheduledBuffers == 0 {
                onPlaybackStateChanged(false)
            }
        }
    }

    private func teardownOnQueue() {
        playbackGeneration &+= 1
        if let engine {
            if isCapturing {
                engine.inputNode.removeTap(onBus: 0)
            }
            playerNode?.stop()
            engine.stop()
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
