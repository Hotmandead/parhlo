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
    public private(set) var isVoiceProcessingActive: Bool = false
    public private(set) var isPlayingAudio: Bool = false
    public private(set) var inputRMSLevel: Float = 0.0

    @ObservationIgnored public var voiceProcessingEnabled: Bool = true
    @ObservationIgnored public var localVADThreshold: Float = 0.025
    @ObservationIgnored public var localVADEnabled: Bool = true

    @ObservationIgnored public var onAudioChunk: (@Sendable (Data) -> Void)?
    @ObservationIgnored public var onLocalVoiceActivity: (@Sendable () -> Void)?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var playerNode: AVAudioPlayerNode?
    @ObservationIgnored private var playbackConverter: AVAudioConverter?
    @ObservationIgnored private var playbackSourceFormat: AVAudioFormat?
    @ObservationIgnored private var playbackTargetFormat: AVAudioFormat?
    @ObservationIgnored private var activeScheduledBuffers: Int = 0
    @ObservationIgnored private var lastLocalVADTrigger: Date = .distantPast

    public init() {}

    /// Starts full-duplex `AVAudioEngine` capture (16 kHz Int16 PCM) and playback (24 kHz Int16 PCM).
    public func start() throws {
        guard !isRunning else { return }

        let audioEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        audioEngine.attach(player)

        let inputNode = audioEngine.inputNode
        if voiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                isVoiceProcessingActive = true
            } catch {
                // Keep running if hardware/virtual device rejects voice processing.
                isVoiceProcessingActive = false
            }
        } else {
            isVoiceProcessingActive = false
        }

        let mainMixer = audioEngine.mainMixerNode
        let mixerFormat = mainMixer.outputFormat(forBus: 0)
        audioEngine.connect(player, to: mainMixer, format: mixerFormat)

        guard let downSourceFormat = Self.makePCMInt16Format(sampleRate: Self.downstreamSampleRate) else {
            throw AudioEngineError.unsupportedFormat
        }
        guard let downConverter = AVAudioConverter(from: downSourceFormat, to: mixerFormat) else {
            throw AudioEngineError.converterInitializationFailed
        }

        let hardwareInputFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareInputFormat.sampleRate > 0, hardwareInputFormat.channelCount > 0 else {
            throw AudioEngineError.unsupportedFormat
        }
        guard let upTargetFormat = Self.makePCMInt16Format(sampleRate: Self.upstreamSampleRate) else {
            throw AudioEngineError.unsupportedFormat
        }
        guard let upConverter = AVAudioConverter(from: hardwareInputFormat, to: upTargetFormat) else {
            throw AudioEngineError.converterInitializationFailed
        }

        let chunkCallback = onAudioChunk
        let vadThreshold = localVADThreshold
        let vadEnabled = localVADEnabled

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareInputFormat) { [weak self] buffer, _ in
            guard let pcmData = Self.convertToPCMInt16Data(
                buffer: buffer,
                converter: upConverter,
                targetFormat: upTargetFormat
            ) else {
                return
            }

            let rms = Self.computePCM16RMS(pcmData)
            chunkCallback?(pcmData)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputRMSLevel = rms
                if vadEnabled && self.isPlayingAudio && rms >= vadThreshold {
                    let now = Date()
                    if now.timeIntervalSince(self.lastLocalVADTrigger) >= 0.4 {
                        self.lastLocalVADTrigger = now
                        self.onLocalVoiceActivity?()
                    }
                }
            }
        }

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
        self.isRunning = true
    }

    /// Stops audio capture and playback and tears down the `AVAudioEngine` graph.
    public func stop() {
        guard isRunning else { return }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            playerNode?.stop()
            engine.stop()
        }

        engine = nil
        playerNode = nil
        playbackConverter = nil
        playbackSourceFormat = nil
        playbackTargetFormat = nil
        activeScheduledBuffers = 0
        isPlayingAudio = false
        isVoiceProcessingActive = false
        inputRMSLevel = 0
        isRunning = false
    }

    /// Schedules a downstream 24 kHz 16-bit mono PCM chunk for low-latency playback.
    public func enqueuePlayback(pcm24kData: Data) {
        guard isRunning,
              let playerNode,
              let playbackConverter,
              let playbackSourceFormat,
              let playbackTargetFormat,
              !pcm24kData.isEmpty else {
            return
        }

        guard let floatBuffer = Self.convertPCM24kInt16ToPlaybackBuffer(
            pcmData: pcm24kData,
            sourceFormat: playbackSourceFormat,
            converter: playbackConverter,
            targetFormat: playbackTargetFormat
        ) else {
            return
        }

        activeScheduledBuffers += 1
        isPlayingAudio = true
        if !playerNode.isPlaying {
            playerNode.play()
        }

        playerNode.scheduleBuffer(floatBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeScheduledBuffers = max(0, self.activeScheduledBuffers - 1)
                if self.activeScheduledBuffers == 0 {
                    self.isPlayingAudio = false
                }
            }
        }
    }

    /// Immediately flushes queued playback buffers on VAD or manual barge-in.
    public func stopPlaybackImmediately() {
        activeScheduledBuffers = 0
        isPlayingAudio = false
        guard let playerNode else { return }
        playerNode.stop()
        if isRunning {
            playerNode.play()
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
