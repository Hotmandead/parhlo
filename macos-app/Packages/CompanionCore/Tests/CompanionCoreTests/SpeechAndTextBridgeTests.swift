@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CompanionCore

@Suite("Speech and Text Bridge Tests")
struct SpeechAndTextBridgeTests {
    @Test("TextUpMessage JSON encoding and decoding match schemas.py")
    func textUpMessageSchemaParity() throws {
        let message = TextUpMessage(text: "Where is the export button?")
        let data = try JSONEncoder().encode(message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["type"] as? String == "text_up")
        #expect(json["text"] as? String == "Where is the export button?")

        let decoded = try JSONDecoder().decode(TextUpMessage.self, from: data)
        #expect(decoded == message)

        let upstream = UpstreamMessage.textUp(message)
        let upstreamData = try JSONEncoder().encode(upstream)
        let upstreamJSON = try #require(JSONSerialization.jsonObject(with: upstreamData) as? [String: Any])
        #expect(upstreamJSON["type"] as? String == "text_up")
        #expect(upstreamJSON["text"] as? String == "Where is the export button?")
        #expect(try JSONDecoder().decode(UpstreamMessage.self, from: upstreamData) == upstream)
    }

    @Test("OverlayStateStore dictationText and HudStateMessage transcript handling")
    @MainActor
    func overlayStoreDictationAndHudTranscripts() throws {
        let store = OverlayStateStore()
        #expect(store.dictationText == "")
        #expect(store.isEditingPrompt == false)

        store.dictationText = "Explain this error"
        #expect(store.dictationText == "Explain this error")

        let coordinator = AppCoordinator(overlayStore: store)
        let initialCount = store.messages.count

        // Local status messages should update transcriptSnippet without polluting chat history.
        store.apply(HudStateMessage(state: .listening, transcriptSnippet: "Listening… (Control+Option to stop)"))
        #expect(store.transcriptSnippet == "Listening… (Control+Option to stop)")
        #expect(store.messages.count == initialCount)

        // Incoming assistant transcript from sidecar updates transcriptSnippet and appends once.
        let assistantPayload = """
        {"type":"hud_state","state":"listening","transcript_snippet":"Click the blue Build button in the toolbar."}
        """
        try coordinator.webSocketClient.handleIncomingText(assistantPayload)
        #expect(store.transcriptSnippet == "Click the blue Build button in the toolbar.")
        #expect(store.messages.count == initialCount + 1)
        #expect(store.messages.last?.isUser == false)
        #expect(store.messages.last?.text == "Click the blue Build button in the toolbar.")

        // Duplicate assistant transcript does not append twice.
        try coordinator.webSocketClient.handleIncomingText(assistantPayload)
        #expect(store.messages.count == initialCount + 1)
    }

    @Test("AppCoordinator.sendTextPrompt clears dictationText, appends user message, and ignores whitespace")
    @MainActor
    func sendTextPromptBehavior() {
        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store
        )
        let initialCount = store.messages.count

        store.dictationText = "   "
        coordinator.sendTextPrompt("   \n\t ")
        #expect(store.messages.count == initialCount)
        #expect(store.dictationText == "   ")

        store.dictationText = "How do I fix this?"
        coordinator.sendTextPrompt("  How do I fix this?  ")

        #expect(store.dictationText == "")
        #expect(store.messages.count == initialCount + 1)
        #expect(store.messages.last?.isUser == true)
        #expect(store.messages.last?.text == "How do I fix this?")

        coordinator.webSocketClient.disconnect()
    }

    @Test("Live dictation updates focused empty/dictated prompt without clobbering manual text")
    @MainActor
    func liveDictationFocusAndOutputMuteBehavior() {
        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store
        )

        store.isEditingPrompt = true
        coordinator.applyLiveDictationTranscript("What is on my screen")
        #expect(store.dictationText == "What is on my screen")

        coordinator.applyLiveDictationTranscript("What is on my screen right now")
        #expect(store.dictationText == "What is on my screen right now")

        // Manual edit while focused should not be overwritten by subsequent speech updates.
        store.dictationText = "Typed manually"
        coordinator.applyLiveDictationTranscript("Ignored dictation")
        #expect(store.dictationText == "Typed manually")

        coordinator.setOutputMuted(true)
        #expect(coordinator.audioManager.isOutputMuted == true)
        coordinator.setOutputMuted(false)
        #expect(coordinator.audioManager.isOutputMuted == false)

        coordinator.webSocketClient.disconnect()
    }

    @Test("SpeechRecognitionManager normalizes multi-channel mic buffers to mono Float32 PCM")
    func speechBufferNormalization() throws {
        let monoFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let monoBuffer = try #require(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 512))
        monoBuffer.frameLength = 512
        var converter: AVAudioConverter?
        var sourceFormat: AVAudioFormat?

        let passthrough = try #require(SpeechRecognitionManager.normalizeBufferForSpeech(
            monoBuffer,
            cachedConverter: &converter,
            cachedSourceFormat: &sourceFormat
        ))
        #expect(passthrough === monoBuffer)
        #expect(converter == nil)

        let discrete3ChLayout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let multiChannelFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            interleaved: false,
            channelLayout: discrete3ChLayout
        )
        let multiBuffer = try #require(AVAudioPCMBuffer(pcmFormat: multiChannelFormat, frameCapacity: 512))
        multiBuffer.frameLength = 512
        if let channels = multiBuffer.floatChannelData {
            for frame in 0..<512 {
                channels[0][frame] = 0.25
                channels[1][frame] = 0.0
                channels[2][frame] = 0.0
            }
        }

        let normalized = try #require(SpeechRecognitionManager.normalizeBufferForSpeech(
            multiBuffer,
            cachedConverter: &converter,
            cachedSourceFormat: &sourceFormat
        ))
        #expect(normalized.format.channelCount == 1)
        #expect(normalized.format.commonFormat == .pcmFormatFloat32)
        #expect(normalized.frameLength == 512)
        let normalizedSamples = try #require(normalized.floatChannelData?[0])
        #expect(abs(normalizedSamples[0] - 0.25) < 0.001)
        #expect(abs(normalizedSamples[511] - 0.25) < 0.001)

        // When channel 0 is silent on an aggregate device and channel 1 carries mic audio, channel 1 is selected.
        if let channels = multiBuffer.floatChannelData {
            for frame in 0..<512 {
                channels[0][frame] = 0.0
                channels[1][frame] = -0.35
                channels[2][frame] = 0.0
            }
        }
        let channel1Normalized = try #require(SpeechRecognitionManager.normalizeBufferForSpeech(
            multiBuffer,
            cachedConverter: &converter,
            cachedSourceFormat: &sourceFormat
        ))
        let channel1Samples = try #require(channel1Normalized.floatChannelData?[0])
        #expect(abs(channel1Samples[0] - (-0.35)) < 0.001)
    }

    @Test("InputTranscriptMessage JSON round-trip matches DownstreamEvent schema")
    func inputTranscriptDownstreamDecoding() throws {
        let json = """
        {"type":"input_transcript","text":"Hello, how are you?","is_final":true}
        """
        let event = try JSONDecoder().decode(DownstreamEvent.self, from: Data(json.utf8))
        #expect(event == .inputTranscript(InputTranscriptMessage(text: "Hello, how are you?", isFinal: true)))

        let encoded = try JSONEncoder().encode(event)
        let dict = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(dict["type"] as? String == "input_transcript")
        #expect(dict["text"] as? String == "Hello, how are you?")
        #expect(dict["is_final"] as? Bool == true)
    }

    @Test("Live speech populates input field and auto-sends to chat when speech stops")
    @MainActor
    func liveSpeechPopulatesInputAndAutoSendsOnSpeechStop() async {
        struct StubOfflineQA: OfflineQASession {
            func answer(prompt: String, context: OfflineScreenContext) async throws -> String {
                "Received: \(prompt)"
            }
        }

        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store,
            offlineEngine: StubOfflineQA()
        )
        coordinator.backendMode = .offlineOnly
        coordinator.setOutputMuted(true)
        coordinator.speechStopAutoSendDelay = 0.08
        coordinator.finalTranscriptAutoSendDelay = 0.03
        coordinator.isSessionActive = true
        let initialCount = store.messages.count

        // Partial results populate the input box without sending prematurely.
        coordinator.handleLiveSpeechTranscript("Hello", isFinal: false)
        #expect(store.dictationText == "Hello")
        #expect(store.messages.count == initialCount)

        try? await Task.sleep(for: .milliseconds(30))
        coordinator.handleLiveSpeechTranscript("Hello, how are you?", isFinal: false)
        #expect(store.dictationText == "Hello, how are you?")
        #expect(store.messages.count == initialCount)

        // After speech stops (beyond 80ms delay), dictated input clears and sends to chat.
        try? await Task.sleep(for: .milliseconds(160))
        #expect(store.dictationText == "")
        let userMessages = store.messages.filter { $0.isUser }
        #expect(userMessages.last?.text == "Hello, how are you?")

        // Manual edit while focused must NOT auto-send.
        store.isEditingPrompt = true
        coordinator.handleLiveSpeechTranscript("Draft question", isFinal: false)
        #expect(store.dictationText == "Draft question")
        store.dictationText = "Draft question edited manually"
        coordinator.handleLiveSpeechTranscript("Ignored update", isFinal: false)
        try? await Task.sleep(for: .milliseconds(140))
        #expect(store.dictationText == "Draft question edited manually")
        #expect(store.messages.filter { $0.isUser }.count == userMessages.count)

        // Stopping session flushes pending unedited dictation prompt immediately.
        store.dictationText = ""
        store.isEditingPrompt = false
        coordinator.handleLiveSpeechTranscript("Send on stop", isFinal: false)
        #expect(store.dictationText == "Send on stop")
        coordinator.stopSession()
        #expect(store.dictationText == "")
        #expect(store.messages.filter { $0.isUser }.last?.text == "Send on stop")

        coordinator.webSocketClient.disconnect()
    }

    @Test("AppCoordinator filters recent assistant output echo from speech dictation")
    @MainActor
    func assistantOutputEchoIsFiltered() throws {
        let now = Date()
        let assistantNorm = AppCoordinator.normalizedEchoComparisonText("Hello, I'm doing great, thank you. How can I assist you today?")
        #expect(
            AppCoordinator.isLikelyAssistantEcho(
                transcript: "I'm doing great, thank you",
                recentAssistantText: assistantNorm,
                lastAssistantActivityAt: now.addingTimeInterval(-0.6),
                now: now
            ) == true
        )
        #expect(
            AppCoordinator.isLikelyAssistantEcho(
                transcript: "Where is the export button?",
                recentAssistantText: assistantNorm,
                lastAssistantActivityAt: now.addingTimeInterval(-0.6),
                now: now
            ) == false
        )
        #expect(
            AppCoordinator.isLikelyAssistantEcho(
                transcript: "I'm doing great, thank you",
                recentAssistantText: assistantNorm,
                lastAssistantActivityAt: now.addingTimeInterval(-4.0),
                now: now
            ) == false
        )

        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store
        )
        coordinator.isSessionActive = true
        try coordinator.webSocketClient.handleIncomingText(
            #"{"type":"hud_state","state":"listening","transcript_snippet":"Hello, I am doing great today."}"#
        )
        coordinator.handleLiveSpeechTranscript("I am doing great", isFinal: false)
        #expect(store.dictationText == "")

        coordinator.handleLiveSpeechTranscript("Explain this Xcode error", isFinal: false)
        #expect(store.dictationText == "Explain this Xcode error")

        coordinator.isSessionActive = false
        coordinator.webSocketClient.disconnect()
    }

    @Test("AppCoordinator surfaces audio and speech error callbacks into overlayStore")
    @MainActor
    func surfacesAudioAndSpeechErrors() async {
        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store
        )
        let initialCount = store.messages.count

        coordinator.audioManager.onError?("Hardware tap stalled")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.lastStatusError == "Audio start failed: Hardware tap stalled")
        #expect(store.messages.count == initialCount + 1)
        #expect(store.messages.last?.text == "Audio start failed: Hardware tap stalled")

        // Duplicate identical audio error should not spam chat history.
        coordinator.audioManager.onError?("Hardware tap stalled")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.count == initialCount + 1)

        coordinator.webSocketClient.disconnect()
    }

    @Test("SpeechRecognitionManager.resetTranscript clears transcript state")
    @MainActor
    func speechManagerResetTranscriptClearsState() {
        let manager = SpeechRecognitionManager()
        manager.resetTranscript()
        #expect(manager.latestTranscript == "")
        #expect(manager.isListening == false)
    }

    @Test("AppCoordinator.runOfflineFallback does not duplicate assistant reply when session is active")
    @MainActor
    func offlineFallbackDoesNotDuplicateChatWhenSessionActive() async {
        struct StubOfflineQA: OfflineQASession {
            func answer(prompt: String, context: OfflineScreenContext) async throws -> String {
                "Click the Export button in the top-right toolbar."
            }
        }

        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store,
            offlineEngine: StubOfflineQA()
        )
        coordinator.privacyFilter.addExcludedBundleID(
            Bundle.main.bundleIdentifier ?? "com.apple.dt.xctest.tool"
        )
        coordinator.privacyFilter.evaluateFrontmostApplication(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.apple.dt.xctest.tool",
            appName: "TestRunner"
        )
        coordinator.isSessionActive = true
        let initialCount = store.messages.count

        await coordinator.runOfflineFallback(for: "Where is export?")

        let matching = store.messages.filter {
            !$0.isUser && $0.text == "Click the Export button in the top-right toolbar."
        }
        #expect(matching.count == 1)
        #expect(store.messages.count == initialCount + 1)
        #expect(store.hudState == .listening)
        #expect(store.transcriptSnippet == "Click the Export button in the top-right toolbar.")

        coordinator.isSessionActive = false
        coordinator.webSocketClient.disconnect()
    }

    @Test("SpeechRecognitionManager.start aborts cleanly if stop is called during async authorization")
    @MainActor
    func speechManagerStopDuringAuthorizationCancelsStart() async {
        let manager = SpeechRecognitionManager()
        var startedCount = 0
        var authContinuation: CheckedContinuation<Bool, Never>?

        manager.authorizationOverride = {
            await withCheckedContinuation { continuation in
                authContinuation = continuation
            }
        }
        manager.recognitionStartOverride = {
            startedCount += 1
        }

        let startTask = Task { @MainActor in
            await manager.start()
        }
        await Task.yield()

        manager.stop()
        authContinuation?.resume(returning: true)
        await startTask.value

        #expect(startedCount == 0)
        #expect(manager.isListening == false)
    }

    @Test("AppCoordinator ignores stale speech start completion when privacy pause activates mid-startup")
    @MainActor
    func coordinatorPrivacyPauseCancelsPendingSpeechStartup() async {
        let speech = SpeechRecognitionManager()
        var startedCount = 0
        var authContinuation: CheckedContinuation<Bool, Never>?

        speech.authorizationOverride = {
            await withCheckedContinuation { continuation in
                authContinuation = continuation
            }
        }
        speech.recognitionStartOverride = {
            startedCount += 1
        }

        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            speechManager: speech
        )
        coordinator.isSessionActive = true
        let startGen = coordinator.captureCycleGeneration

        let startupTask = Task { @MainActor in
            await coordinator.startSpeechRecognitionIfActive(expectedCaptureGeneration: startGen)
        }
        await Task.yield()

        // Protected app activates while speech authorization is pending.
        coordinator.privacyFilter.evaluateFrontmostApplication(
            bundleIdentifier: "com.1password.1password",
            appName: "1Password"
        )
        authContinuation?.resume(returning: true)
        await startupTask.value

        #expect(startedCount == 0)
        #expect(speech.isListening == false)
        #expect(coordinator.isUsingSidecarAudioFallback == false)

        coordinator.isSessionActive = false
        coordinator.webSocketClient.disconnect()
    }

    @Test("AppCoordinator.stopSession commits sidecar fallback input transcript without re-sending prompt")
    @MainActor
    func stopSessionCommitsFallbackTranscriptLocallyWithoutDuplicateSend() async {
        struct ForbiddenOfflineQA: OfflineQASession {
            func answer(prompt: String, context: OfflineScreenContext) async throws -> String {
                Issue.record("stopSession should commit fallback transcript locally without invoking sendTextPrompt/offline fallback")
                return "Unexpected"
            }
        }

        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store,
            offlineEngine: ForbiddenOfflineQA()
        )
        coordinator.backendMode = .auto
        coordinator.isSessionActive = true
        coordinator.enableSidecarAudioFallbackForTesting(true)
        let initialCount = store.messages.count

        coordinator.handleFallbackInputTranscript(
            InputTranscriptMessage(text: "Explain this stack trace", isFinal: false)
        )
        #expect(store.dictationText == "Explain this stack trace")

        coordinator.stopSession()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(store.dictationText == "")
        #expect(store.hudState == .idle)
        #expect(store.messages.count == initialCount + 1)
        #expect(store.messages.last?.isUser == true)
        #expect(store.messages.last?.text == "Explain this stack trace")

        coordinator.webSocketClient.disconnect()
    }

    @Test("AppCoordinator processes downstream barge_in synchronously before subsequent hud_state")
    @MainActor
    func downstreamBargeInResetsStreamingTurnBeforeNextHudState() throws {
        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store
        )
        let initialCount = store.messages.count

        try coordinator.webSocketClient.handleIncomingText(
            #"{"type":"hud_state","state":"listening","transcript_snippet":"First turn"}"#
        )
        try coordinator.webSocketClient.handleIncomingText(
            #"{"type":"barge_in","reason":"vad_interrupted"}"#
        )
        try coordinator.webSocketClient.handleIncomingText(
            #"{"type":"hud_state","state":"listening","transcript_snippet":"Second turn"}"#
        )

        #expect(store.messages.count == initialCount + 2)
        #expect(store.messages[initialCount].text == "First turn")
        #expect(store.messages[initialCount + 1].text == "Second turn")

        coordinator.webSocketClient.disconnect()
    }

    @Test("AppCoordinator preserves early speech buffers on local VAD barge-in while resetting on normal playback end")
    @MainActor
    func localBargeInDoesNotResetSpeechTranscript() async {
        let speech = SpeechRecognitionManager()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            speechManager: speech
        )
        coordinator.isSessionActive = true

        coordinator.audioManager.setPlayingStateForTesting(true)
        #expect(speech.resetTranscriptCountForTesting == 1)

        // Local VAD barge-in stops playback without resetting the newly started user speech buffers.
        coordinator.audioManager.onLocalVoiceActivity?()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(coordinator.audioManager.isPlayingAudio == false)
        #expect(speech.resetTranscriptCountForTesting == 1)

        // Normal playback completion (without local barge-in) resets stale recognizer state.
        coordinator.audioManager.setPlayingStateForTesting(true)
        #expect(speech.resetTranscriptCountForTesting == 2)
        coordinator.audioManager.setPlayingStateForTesting(false)
        #expect(speech.resetTranscriptCountForTesting == 3)

        coordinator.isSessionActive = false
        coordinator.webSocketClient.disconnect()
    }

    @Test("AppCoordinator.runOfflineFallback exits thinking state when offline reply is empty")
    @MainActor
    func offlineFallbackEmptyReplyResetsThinkingState() async {
        struct EmptyOfflineQA: OfflineQASession {
            func answer(prompt: String, context: OfflineScreenContext) async throws -> String {
                "   \n  "
            }
        }

        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store,
            offlineEngine: EmptyOfflineQA()
        )
        coordinator.privacyFilter.addExcludedBundleID(
            Bundle.main.bundleIdentifier ?? "com.apple.dt.xctest.tool"
        )
        coordinator.privacyFilter.evaluateFrontmostApplication(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.apple.dt.xctest.tool",
            appName: "TestRunner"
        )

        await coordinator.runOfflineFallback(for: "Hello?")
        #expect(store.hudState == .idle)

        coordinator.webSocketClient.disconnect()
    }
}
