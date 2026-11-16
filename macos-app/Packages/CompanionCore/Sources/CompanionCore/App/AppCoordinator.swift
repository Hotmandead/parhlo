import AppKit
import Foundation
import Observation

/// Coordinates live voice capture, <= 1 FPS screen/AX capture, WebSocket bridging, and overlay rendering.
@MainActor
@Observable
public final class AppCoordinator {
    public var overlayStore: OverlayStateStore
    public let permissionsManager: PermissionsManager
    public let privacyFilter: PrivacyFilter
    public let captureEngine: CaptureEngine
    public let webSocketClient: SidecarWebSocketClient
    public let audioManager: AudioEngineManager
    public let speechManager: SpeechRecognitionManager
    public let offlineSpeechManager: OfflineSpeechManager
    public let offlineEngine: any OfflineQASession
    public let hotkeyManager: GlobalHotkeyManager
    public let overlayController: OverlayWindowController

    public var backendMode: AssistantBackendMode = .auto
    public private(set) var isSessionActive: Bool = false
    public private(set) var lastStatusError: String?
    @ObservationIgnored private var lastSurfacedSpeechError: String?
    @ObservationIgnored private var lastSurfacedAudioError: String?
    @ObservationIgnored private var lastAppliedDictationText: String = ""
    @ObservationIgnored private var isStreamingAssistantTurn: Bool = false

    public init(
        sidecarURL: URL = SidecarWebSocketClient.defaultURL,
        overlayStore: OverlayStateStore? = nil,
        permissionsManager: PermissionsManager? = nil,
        hotkeyMode: HotkeyActivationMode = .smartTapOrHold,
        speechManager: SpeechRecognitionManager? = nil,
        offlineSpeechManager: OfflineSpeechManager? = nil,
        offlineEngine: (any OfflineQASession)? = nil
    ) {
        let store = overlayStore ?? OverlayStateStore()
        let permissions = permissionsManager ?? PermissionsManager()
        let privacy = PrivacyFilter(overlayStore: store)
        let capture = CaptureEngine(privacyFilter: privacy)
        let ws = SidecarWebSocketClient(url: sidecarURL, overlayStore: store)
        let audio = AudioEngineManager()
        let speech = speechManager ?? SpeechRecognitionManager()
        let offlineSpeech = offlineSpeechManager ?? OfflineSpeechManager()
        let offline = offlineEngine ?? OfflineAssistantEngine()
        let hotkey = GlobalHotkeyManager(mode: hotkeyMode)
        let overlay = OverlayWindowController(store: store)

        self.overlayStore = store
        self.permissionsManager = permissions
        self.privacyFilter = privacy
        self.captureEngine = capture
        self.webSocketClient = ws
        self.audioManager = audio
        self.speechManager = speech
        self.offlineSpeechManager = offlineSpeech
        self.offlineEngine = offline
        self.hotkeyManager = hotkey
        self.overlayController = overlay

        wireCallbacks()
    }

    /// Installs global `Control+Option` monitoring on app launch.
    public func bootstrap() {
        hotkeyManager.startMonitoring()
    }

    /// Toggles the active screen + voice session on or off.
    public func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    /// Starts WebSocket connection, `AVAudioEngine` voice I/O, on-demand screen capture, and HUD overlay.
    public func startSession() {
        guard !isSessionActive else { return }
        lastStatusError = nil
        lastSurfacedSpeechError = nil
        lastSurfacedAudioError = nil
        offlineSpeechManager.stopImmediately()
        permissionsManager.refresh()

        isSessionActive = true
        lastAppliedDictationText = ""
        isStreamingAssistantTurn = false
        hotkeyManager.syncSessionActive(true)
        privacyFilter.startObserving()

        overlayController.showOverlay()
        overlayStore.apply(HudStateMessage(
            state: privacyFilter.isPaused ? .privacyPaused : .listening,
            transcriptSnippet: privacyFilter.isPaused ? "Paused for protected app" : "Listening… (Control+Option to stop)"
        ))

        webSocketClient.connect()

        switch permissionsManager.microphone {
        case .granted:
            startAudioCapture()
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive else { return }
                await self.speechManager.start()
                guard self.isSessionActive, let speechError = self.speechManager.lastError else { return }
                self.surfaceSpeechErrorOnce(speechError)
            }
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive else { return }
                await self.permissionsManager.requestMicrophone()
                guard self.isSessionActive else { return }
                guard self.permissionsManager.microphone == .granted else {
                    self.surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
                    return
                }
                self.startAudioCapture()
                await self.speechManager.start()
                guard self.isSessionActive, let speechError = self.speechManager.lastError else { return }
                self.surfaceSpeechErrorOnce(speechError)
            }
        case .denied:
            surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
        }

        captureEngine.startSessionCapture(interval: 1.0) { [weak self] contextMessage in
            await self?.sendScreenContextIfConnected(contextMessage)
        }

        Task { @MainActor [weak self] in
            await self?.sendStartControlWhenReady()
        }
    }

    private func startAudioCapture() {
        do {
            try audioManager.start()
        } catch {
            surfaceAudioErrorOnce("Audio start failed: \(error.localizedDescription)")
        }
    }

    /// Stops voice/screen capture, clears active annotations, and closes the session.
    public func stopSession() {
        guard isSessionActive else { return }

        isSessionActive = false
        lastAppliedDictationText = ""
        isStreamingAssistantTurn = false
        hotkeyManager.syncSessionActive(false)
        captureEngine.stopSessionCapture()
        speechManager.stop()
        offlineSpeechManager.stopImmediately()
        audioManager.stop()
        privacyFilter.stopObserving()

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.webSocketClient.send(SessionControlMessage(action: .stopSession))
        }

        overlayStore.clearAll()
        overlayStore.apply(HudStateMessage(state: .idle, transcriptSnippet: nil))
        overlayController.hideOverlay()
    }

    /// Sends a typed or dictated prompt from the `Ask Parhlo…` input bar over `TextUpMessage`.
    public func sendTextPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        overlayStore.dictationText = ""
        lastAppliedDictationText = ""
        isStreamingAssistantTurn = false
        overlayStore.appendChatMessage(isUser: true, text: trimmed)

        if backendMode == .offlineOnly {
            Task { @MainActor [weak self] in
                await self?.runOfflineFallback(for: trimmed)
            }
            return
        }

        if webSocketClient.connectionState != .connected {
            webSocketClient.connect()
        }

        Task { @MainActor [weak self] in
            await self?.transmitTextPromptWhenReady(trimmed)
        }
    }

    /// Mutes or unmutes assistant voice output, triggering manual barge-in when muted.
    public func setOutputMuted(_ muted: Bool) {
        audioManager.setOutputMuted(muted)
        if muted {
            offlineSpeechManager.stopImmediately()
            triggerManualBargeIn()
        }
    }

    /// Immediately stops playback and fades annotations, notifying the sidecar of manual barge-in.
    public func triggerManualBargeIn() {
        offlineSpeechManager.stopImmediately()
        audioManager.stopPlaybackImmediately()
        overlayStore.handleBargeIn(BargeInMessage(reason: .manual))

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.webSocketClient.send(SessionControlMessage(action: .bargeInManual))
        }
    }

    /// Shows the Phase 2/3 visual overlay demo without requiring a live sidecar connection.
    public func triggerDemoAnnotations() {
        overlayController.showOverlay()
        overlayStore.loadDemoAnnotations(for: overlayController.currentOverlaySize)
    }

    /// Clears all annotations and hides the overlay when no session is active.
    public func clearOverlay() {
        overlayStore.clearAll()
        if !isSessionActive {
            overlayStore.apply(HudStateMessage(state: .idle, transcriptSnippet: nil))
            overlayController.hideOverlay()
        }
    }

    private func wireCallbacks() {
        webSocketClient.onAudioDown = { [weak self] audioMessage in
            guard let data = Data(base64Encoded: audioMessage.pcmB64) else { return }
            Task { @MainActor [weak self] in
                self?.audioManager.enqueuePlayback(pcm24kData: data)
            }
        }

        webSocketClient.onBargeIn = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isStreamingAssistantTurn = false
                self?.audioManager.stopPlaybackImmediately()
            }
        }

        audioManager.onAudioChunk = { [weak self] pcm16kData in
            let b64 = pcm16kData.base64EncodedString()
            Task { @MainActor [weak self] in
                guard let self,
                      self.isSessionActive,
                      self.webSocketClient.connectionState == .connected else {
                    return
                }
                try? await self.webSocketClient.send(AudioUpMessage(pcmB64: b64))
            }
        }

        audioManager.onRawAudioBuffer = { [weak speech = self.speechManager] buffer in
            speech?.appendAudioBuffer(buffer)
        }

        speechManager.onTranscriptUpdate = { [weak self] transcript, _ in
            guard let self, self.isSessionActive else { return }
            self.applyLiveDictationTranscript(transcript)
        }

        speechManager.onError = { [weak self] message in
            guard let self, self.isSessionActive else { return }
            self.surfaceSpeechErrorOnce(message)
        }

        overlayStore.onHudStateApplied = { [weak self] message in
            self?.handleAppliedHudState(message)
        }

        audioManager.onLocalVoiceActivity = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive else { return }
                self.audioManager.stopPlaybackImmediately()
            }
        }

        audioManager.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.surfaceAudioErrorOnce("Audio start failed: \(message)")
            }
        }

        hotkeyManager.onSessionRequested = { [weak self] active in
            guard let self else { return }
            if active && !self.isSessionActive {
                self.startSession()
            } else if !active && self.isSessionActive {
                self.stopSession()
            }
        }
    }

    private func sendStartControlWhenReady() async {
        // Wait briefly for WebSocket handshake if connecting.
        for _ in 0..<20 {
            guard isSessionActive else { return }
            if webSocketClient.connectionState == .connected {
                try? await webSocketClient.send(SessionControlMessage(action: .startSession))
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func transmitTextPromptWhenReady(_ prompt: String) async {
        for _ in 0..<20 {
            if webSocketClient.connectionState == .connected {
                do {
                    if !isSessionActive && !privacyFilter.isPaused {
                        if let screenContext = try? await captureEngine.captureOnce(respectRateLimit: false) {
                            overlayController.showOverlay()
                            overlayStore.triggerCapturePulse()
                            try? await webSocketClient.send(screenContext)
                        }
                    }
                    try await webSocketClient.send(TextUpMessage(text: prompt))
                    return
                } catch {
                    if backendMode == .auto {
                        await runOfflineFallback(for: prompt)
                        return
                    }
                    let notice = "Sidecar not connected at \(webSocketClient.url.absoluteString) — start Docker sidecar with 'docker compose up -d'."
                    lastStatusError = notice
                    overlayStore.appendChatMessage(isUser: false, text: notice)
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if backendMode == .auto {
            await runOfflineFallback(for: prompt)
            return
        }

        let notice = "Sidecar not connected at \(webSocketClient.url.absoluteString) — start Docker sidecar with 'docker compose up -d'."
        lastStatusError = notice
        overlayStore.appendChatMessage(isUser: false, text: notice)
    }

    /// Runs on-device Phase 5 fallback Q&A over redacted screen OCR + AX context and speaks the response locally.
    public func runOfflineFallback(for prompt: String) async {
        overlayStore.apply(HudStateMessage(state: .thinking, transcriptSnippet: "Thinking on-device…"))

        let context: OfflineScreenContext
        if !privacyFilter.isPaused,
           let captured = try? await captureEngine.captureOfflineContext() {
            overlayController.showOverlay()
            overlayStore.triggerCapturePulse()
            context = captured
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            context = OfflineScreenContext(
                sanitizedOCRText: "",
                axElements: [],
                frontmostBundleID: frontmost?.bundleIdentifier,
                frontmostAppName: frontmost?.localizedName
            )
        }

        do {
            let reply = try await offlineEngine.answer(prompt: prompt, context: context)
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            isStreamingAssistantTurn = false
            overlayStore.appendChatMessage(isUser: false, text: trimmed)
            overlayStore.apply(HudStateMessage(state: isSessionActive ? .listening : .idle, transcriptSnippet: trimmed))
            if !isSessionActive {
                offlineSpeechManager.speak(trimmed, muted: audioManager.isOutputMuted)
            }
        } catch {
            let fallback = "Offline assistant unavailable: \(error.localizedDescription)"
            lastStatusError = fallback
            overlayStore.appendChatMessage(isUser: false, text: fallback)
            overlayStore.apply(HudStateMessage(state: .idle, transcriptSnippet: nil))
        }
    }

    private func handleAppliedHudState(_ message: HudStateMessage) {
        guard let rawSnippet = message.transcriptSnippet else { return }
        let snippet = rawSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return }

        if snippet == "Listening… (Control+Option to stop)"
            || snippet == "Paused for protected app"
            || snippet == "Privacy filter active"
            || snippet.hasPrefix("Paused for ")
            || snippet.hasPrefix("Demo:") {
            return
        }

        let isAssistantTranscript = message.state == .listening || message.state == .drawing
        let isSidecarError = message.state == .idle && snippet.hasPrefix("Sidecar error:")
        guard isAssistantTranscript || isSidecarError else { return }

        if isAssistantTranscript {
            if isStreamingAssistantTurn {
                overlayStore.appendToLastAssistantMessage(rawSnippet)
            } else {
                isStreamingAssistantTurn = true
                overlayStore.appendChatMessage(isUser: false, text: snippet)
            }
        } else {
            isStreamingAssistantTurn = false
            overlayStore.appendChatMessage(isUser: false, text: snippet)
        }
    }

    /// Updates `dictationText` with live speech recognition while preserving non-dictation manual text.
    public func applyLiveDictationTranscript(_ transcript: String) {
        let current = overlayStore.dictationText
        let canReplace = !overlayStore.isEditingPrompt
            || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || current == lastAppliedDictationText
        guard canReplace else { return }
        overlayStore.dictationText = transcript
        lastAppliedDictationText = transcript
    }

    private func surfaceSpeechErrorOnce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, lastSurfacedSpeechError != trimmed else { return }
        lastSurfacedSpeechError = trimmed
        lastStatusError = trimmed
        overlayStore.appendChatMessage(isUser: false, text: trimmed)
    }

    private func surfaceAudioErrorOnce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, lastSurfacedAudioError != trimmed else { return }
        lastSurfacedAudioError = trimmed
        lastStatusError = trimmed
        overlayStore.appendChatMessage(isUser: false, text: trimmed)
    }

    private func sendScreenContextIfConnected(_ message: ScreenContextMessage) async {
        guard isSessionActive, webSocketClient.connectionState == .connected else { return }
        overlayStore.triggerCapturePulse()
        try? await webSocketClient.send(message)
    }
}
