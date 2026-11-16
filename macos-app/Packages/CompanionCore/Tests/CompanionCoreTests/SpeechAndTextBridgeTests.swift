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
                channels[1][frame] = 0.25
                channels[2][frame] = 0.25
            }
        }

        let normalized = try #require(SpeechRecognitionManager.normalizeBufferForSpeech(
            multiBuffer,
            cachedConverter: &converter,
            cachedSourceFormat: &sourceFormat
        ))
        #expect(normalized.format.channelCount == 1)
        #expect(normalized.format.commonFormat == .pcmFormatFloat32)
        #expect(normalized.frameLength > 0)
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
}
