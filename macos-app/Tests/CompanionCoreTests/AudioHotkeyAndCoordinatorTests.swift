import AVFoundation
import AppKit
import Foundation
import Testing
@testable import CompanionCore

@Suite("CompanionCore Phase 4 Tests")
struct AudioHotkeyAndCoordinatorTests {
    @Test("AudioEngineManager converts 48kHz Float32 input buffer to 16kHz Int16 PCM")
    func upstreamAudioConversion() throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let targetFormat = try #require(AudioEngineManager.makePCMInt16Format(sampleRate: 16_000))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: targetFormat))

        let frameCount: AVAudioFrameCount = 4_800 // 100 ms @ 48 kHz
        let inputBuffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount))
        inputBuffer.frameLength = frameCount
        let channelData = try #require(inputBuffer.floatChannelData?[0])
        for i in 0..<Int(frameCount) {
            channelData[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0) * 0.4)
        }

        let pcm16 = try #require(
            AudioEngineManager.convertToPCMInt16Data(
                buffer: inputBuffer,
                converter: converter,
                targetFormat: targetFormat
            )
        )

        let expectedBytesApprox = 1_600 * MemoryLayout<Int16>.size
        #expect(pcm16.count >= 2_400)
        #expect(pcm16.count <= expectedBytesApprox + 64)
        #expect(pcm16.count % MemoryLayout<Int16>.size == 0)
        #expect(AudioEngineManager.computePCM16RMS(pcm16) > 0.1)
        #expect(AudioEngineManager.computePCM16RMS(Data(count: 320)) == 0.0)
    }

    @Test("AudioEngineManager converts 24kHz Int16 PCM to 48kHz Float32 playback buffer")
    func downstreamAudioConversion() throws {
        let sourceFormat = try #require(AudioEngineManager.makePCMInt16Format(sampleRate: 24_000))
        let targetFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: sourceFormat, to: targetFormat))

        // 50 ms of 24 kHz Int16 tone (1,200 samples)
        var samples = [Int16](repeating: 0, count: 1_200)
        for i in 0..<samples.count {
            samples[i] = Int16(sin(2.0 * .pi * 523.25 * Double(i) / 24_000.0) * 10_000.0)
        }
        let pcmData = samples.withUnsafeBytes { Data($0) }

        let outBuffer = try #require(
            AudioEngineManager.convertPCM24kInt16ToPlaybackBuffer(
                pcmData: pcmData,
                sourceFormat: sourceFormat,
                converter: converter,
                targetFormat: targetFormat
            )
        )

        #expect(outBuffer.frameLength > 2_000)
        #expect(outBuffer.format.sampleRate == 48_000)
    }

    @Test("ControlOptionChordDetector enforces exact Control+Option chord and smart tap/hold")
    func controlOptionDetector() {
        #expect(ControlOptionChordDetector.isControlOptionChord([.control, .option]) == true)
        #expect(ControlOptionChordDetector.isControlOptionChord([.control]) == false)
        #expect(ControlOptionChordDetector.isControlOptionChord([.option]) == false)
        #expect(ControlOptionChordDetector.isControlOptionChord([.control, .option, .command]) == false)
        #expect(ControlOptionChordDetector.isControlOptionChord([.control, .option, .shift]) == false)

        var detector = ControlOptionChordDetector(mode: .smartTapOrHold, holdThresholdSeconds: 0.35)
        let t0 = Date(timeIntervalSince1970: 1_000)

        // Quick tap toggles session ON and stays ON after release.
        #expect(detector.process(flags: [.control, .option], now: t0) == true)
        #expect(detector.process(flags: [], now: t0.addingTimeInterval(0.12)) == nil)
        #expect(detector.isSessionActive == true)

        // Second quick tap toggles session OFF.
        #expect(detector.process(flags: [.control, .option], now: t0.addingTimeInterval(0.5)) == false)
        #expect(detector.process(flags: [], now: t0.addingTimeInterval(0.6)) == nil)
        #expect(detector.isSessionActive == false)

        // Hold >= 0.35s starts on press and auto-stops on release.
        #expect(detector.process(flags: [.control, .option], now: t0.addingTimeInterval(1.0)) == true)
        #expect(detector.process(flags: [], now: t0.addingTimeInterval(1.5)) == false)
        #expect(detector.isSessionActive == false)
    }

    @Test("GlobalHotkeyManager dispatches Control+Option session requests")
    @MainActor
    func hotkeyManagerDispatch() {
        let manager = GlobalHotkeyManager(mode: .holdToSpeak)
        var events: [Bool] = []
        manager.onSessionRequested = { active in
            events.append(active)
        }

        let t0 = Date(timeIntervalSince1970: 2_000)
        manager.handleModifierFlags([.control, .option], now: t0)
        manager.handleModifierFlags([], now: t0.addingTimeInterval(0.2))

        #expect(events == [true, false])
    }

    @Test("AppCoordinator demo, clear, and manual barge-in coordinate overlay and audio state")
    @MainActor
    func coordinatorBargeInAndOverlay() {
        let coordinator = AppCoordinator()
        coordinator.triggerDemoAnnotations()
        #expect(coordinator.overlayStore.hasAnnotations == true)
        #expect(coordinator.overlayStore.hudState == .drawing)

        coordinator.triggerManualBargeIn()
        #expect(coordinator.overlayStore.hasAnnotations == false)
        #expect(coordinator.audioManager.isPlayingAudio == false)
        #expect(coordinator.overlayStore.hudState == .idle)

        coordinator.triggerDemoAnnotations()
        #expect(coordinator.overlayStore.hudState == .drawing)
        coordinator.overlayStore.handleBargeIn(BargeInMessage(reason: .vadInterrupted))
        #expect(coordinator.overlayStore.hasAnnotations == false)
        #expect(coordinator.overlayStore.hudState == .listening)

        coordinator.clearOverlay()
        #expect(coordinator.overlayStore.hudState == .idle)
    }

    @Test("NotchPanelWindowController toggles between collapsed pill and expanded drawer with sharingType.none")
    @MainActor
    func notchPanelToggleAndSharingType() {
        let coordinator = AppCoordinator()
        let notch = NotchPanelWindowController(coordinator: coordinator, onOpenSettings: {})

        #expect(notch.panel.sharingType == .none)
        #expect(notch.isExpanded == false)
        #expect(notch.panel.canBecomeKey == false)

        notch.setExpanded(true)
        #expect(notch.isExpanded == true)
        #expect(notch.panel.canBecomeKey == true)

        coordinator.overlayStore.appendChatMessage(isUser: true, text: "Where is the filter bar?")
        #expect(coordinator.overlayStore.messages.last?.text == "Where is the filter bar?")
    }
}
