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
    public internal(set) var isSessionActive: Bool = false
    public private(set) var lastStatusError: String?
    public var speechStopAutoSendDelay: TimeInterval = 1.15
    public var finalTranscriptAutoSendDelay: TimeInterval = 0.15
    public var maxSpeechEnergyExtensionDelay: TimeInterval = 2.2
    @ObservationIgnored private var lastSurfacedSpeechError: String?
    @ObservationIgnored private var lastSurfacedAudioError: String?
    @ObservationIgnored private var lastAppliedDictationText: String = ""
    @ObservationIgnored private var isStreamingAssistantTurn: Bool = false
    @ObservationIgnored private var suppressHudStateChatAppend: Bool = false
    @ObservationIgnored private var speechAutoSendTask: Task<Void, Never>?
    @ObservationIgnored private var lastTranscriptChangedAt: Date = .distantPast
    @ObservationIgnored private var lastAutoSendIsFinal: Bool = false
    @ObservationIgnored private var isStartingSpeechRecognition: Bool = false
    @ObservationIgnored private var isUsingSidecarAudioFallback: Bool = false
    @ObservationIgnored private var pendingFallbackUserTranscript: String = ""
    @ObservationIgnored private var lastPlaybackEndedAt: Date = .distantPast
    @ObservationIgnored private var lastAssistantTranscriptAt: Date = .distantPast
    @ObservationIgnored private var recentAssistantNormalizedText: String = ""
    @ObservationIgnored private var audioChunkContinuation: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var audioSendTask: Task<Void, Never>?

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

    deinit {
        speechAutoSendTask?.cancel()
        audioSendTask?.cancel()
        audioChunkContinuation?.finish()
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

        if permissionsManager.microphone == .denied {
            hotkeyManager.syncSessionActive(false)
            surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
            return
        }

        speechAutoSendTask?.cancel()
        speechAutoSendTask = nil
        isSessionActive = true
        lastAppliedDictationText = ""
        lastTranscriptChangedAt = .distantPast
        lastAutoSendIsFinal = false
        isStartingSpeechRecognition = true
        isUsingSidecarAudioFallback = false
        pendingFallbackUserTranscript = ""
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
            if !privacyFilter.isPaused {
                startAudioCapture()
                guard isSessionActive else { return }
                Task { @MainActor [weak self] in
                    await self?.startSpeechRecognitionIfActive()
                }
            } else {
                isStartingSpeechRecognition = false
            }
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive else { return }
                let app: NSApplication? = NSApp
                app?.activate(ignoringOtherApps: true)
                await self.permissionsManager.requestMicrophone()
                guard self.isSessionActive else { return }
                guard self.permissionsManager.microphone == .granted else {
                    self.isStartingSpeechRecognition = false
                    self.surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
                    self.stopSession()
                    return
                }
                guard !self.privacyFilter.isPaused else {
                    self.isStartingSpeechRecognition = false
                    return
                }
                self.startAudioCapture()
                guard self.isSessionActive else { return }
                await self.startSpeechRecognitionIfActive()
            }
        case .denied:
            isStartingSpeechRecognition = false
            surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
            stopSession()
            return
        }

        guard isSessionActive else { return }

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
            stopSession()
        }
    }

    /// Stops voice/screen capture, clears active annotations, and closes the session.
    public func stopSession() {
        guard isSessionActive else { return }

        speechAutoSendTask?.cancel()
        speechAutoSendTask = nil
        let pendingDictatedPrompt = flushableDictatedPrompt()
        let pendingFallbackPrompt = pendingFallbackUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFallbackUserTranscript = ""

        isSessionActive = false
        isStartingSpeechRecognition = false
        isUsingSidecarAudioFallback = false
        lastAppliedDictationText = ""
        lastTranscriptChangedAt = .distantPast
        lastAutoSendIsFinal = false
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

        if let pendingDictatedPrompt {
            sendTextPrompt(pendingDictatedPrompt)
        } else if !pendingFallbackPrompt.isEmpty {
            overlayStore.dictationText = ""
            overlayStore.appendChatMessage(isUser: true, text: pendingFallbackPrompt)
        }
    }

    /// Sends a typed or dictated prompt from the `Ask Parhlo…` input bar over `TextUpMessage`.
    public func sendTextPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        speechAutoSendTask?.cancel()
        speechAutoSendTask = nil
        overlayStore.dictationText = ""
        lastAppliedDictationText = ""
        lastTranscriptChangedAt = .distantPast
        lastAutoSendIsFinal = false
        pendingFallbackUserTranscript = ""
        speechManager.resetTranscript()
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

        webSocketClient.onInputTranscript = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleFallbackInputTranscript(message)
            }
        }

        let (audioStream, audioContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.audioChunkContinuation = audioContinuation
        self.audioSendTask = Task { @MainActor [weak self] in
            for await pcm16kData in audioStream {
                guard !Task.isCancelled else { break }
                guard let self,
                      self.isSessionActive,
                      !self.privacyFilter.isPaused,
                      !self.isStartingSpeechRecognition,
                      self.isUsingSidecarAudioFallback,
                      self.webSocketClient.connectionState == .connected else {
                    continue
                }
                let b64 = pcm16kData.base64EncodedString()
                try? await self.webSocketClient.send(AudioUpMessage(pcmB64: b64))
            }
        }

        audioManager.onAudioChunk = { pcm16kData in
            audioContinuation.yield(pcm16kData)
        }

        audioManager.onRawAudioBuffer = { [weak speech = self.speechManager] buffer in
            speech?.appendAudioBuffer(buffer)
        }

        audioManager.onSpeechEnergyDetected = { [weak self] _ in
            self?.extendSpeechAutoSendOnActiveSpeechIfNeeded()
        }

        audioManager.onPlaybackStateChanged = { [weak self] isPlaying in
            guard let self else { return }
            if !isPlaying {
                self.lastPlaybackEndedAt = Date()
            }
            if self.isSessionActive,
               self.overlayStore.dictationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.speechManager.resetTranscript()
            }
        }

        speechManager.onTranscriptUpdate = { [weak self] transcript, isFinal in
            guard let self, self.isSessionActive else { return }
            self.handleLiveSpeechTranscript(transcript, isFinal: isFinal)
        }

        speechManager.onError = { [weak self] message in
            guard let self, self.isSessionActive else { return }
            self.isUsingSidecarAudioFallback = true
            self.surfaceSpeechErrorOnce(message)
        }

        overlayStore.onHudStateApplied = { [weak self] message in
            self?.handleAppliedHudState(message)
        }

        audioManager.onLocalVoiceActivity = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive else { return }
                self.isStreamingAssistantTurn = false
                self.audioManager.stopPlaybackImmediately()
                self.overlayStore.handleBargeIn(BargeInMessage(reason: .vadInterrupted))
                if self.webSocketClient.connectionState == .connected {
                    try? await self.webSocketClient.send(SessionControlMessage(action: .bargeInManual))
                }
            }
        }

        audioManager.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.surfaceAudioErrorOnce("Audio start failed: \(message)")
                if self.isSessionActive {
                    self.stopSession()
                }
            }
        }

        privacyFilter.onPauseStateChanged = { [weak self] isPaused, _ in
            guard let self, self.isSessionActive else { return }
            if isPaused {
                self.pauseCaptureForPrivacy()
            } else {
                self.resumeCaptureAfterPrivacy()
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
                    if (!isSessionActive || captureEngine.lastCaptureDate == nil) && !privacyFilter.isPaused {
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
            suppressHudStateChatAppend = true
            defer { suppressHudStateChatAppend = false }
            overlayStore.apply(HudStateMessage(state: isSessionActive ? .listening : .idle, transcriptSnippet: trimmed))
            if !isSessionActive {
                offlineSpeechManager.speak(trimmed, muted: audioManager.isOutputMuted)
            }
        } catch {
            let fallback = "Offline assistant unavailable: \(error.localizedDescription)"
            lastStatusError = fallback
            overlayStore.appendChatMessage(isUser: false, text: fallback)
            overlayStore.apply(HudStateMessage(state: isSessionActive ? .listening : .idle, transcriptSnippet: nil))
        }
    }

    private func handleAppliedHudState(_ message: HudStateMessage) {
        guard !suppressHudStateChatAppend else { return }
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
            commitPendingFallbackUserTranscriptIfNeeded()
            if isStreamingAssistantTurn {
                overlayStore.appendToLastAssistantMessage(rawSnippet)
            } else {
                isStreamingAssistantTurn = true
                overlayStore.appendChatMessage(isUser: false, text: snippet)
            }
            if let latestAssistant = overlayStore.messages.last, !latestAssistant.isUser {
                recentAssistantNormalizedText = Self.normalizedEchoComparisonText(latestAssistant.text)
                lastAssistantTranscriptAt = Date()
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

    /// Applies a live speech update into the input field and schedules auto-send when speech stops.
    public func handleLiveSpeechTranscript(_ transcript: String, isFinal: Bool) {
        guard !audioManager.isPlayingAudio else { return }

        let latestAssistantActivity = max(lastPlaybackEndedAt, lastAssistantTranscriptAt)
        if Self.isLikelyAssistantEcho(
            transcript: transcript,
            recentAssistantText: recentAssistantNormalizedText,
            lastAssistantActivityAt: latestAssistantActivity
        ) {
            if overlayStore.dictationText == lastAppliedDictationText {
                overlayStore.dictationText = ""
                lastAppliedDictationText = ""
                speechAutoSendTask?.cancel()
                speechAutoSendTask = nil
                speechManager.resetTranscript()
            }
            return
        }

        let previousApplied = lastAppliedDictationText
        applyLiveDictationTranscript(transcript)

        guard let _ = flushableDictatedPrompt() else {
            speechAutoSendTask?.cancel()
            speechAutoSendTask = nil
            return
        }

        if lastAppliedDictationText != previousApplied || lastTranscriptChangedAt == .distantPast {
            lastTranscriptChangedAt = Date()
        }
        scheduleSpeechAutoSend(isFinal: isFinal)
    }

    private func scheduleSpeechAutoSend(isFinal: Bool) {
        speechAutoSendTask?.cancel()
        lastAutoSendIsFinal = isFinal
        let delay = max(0.0, isFinal ? finalTranscriptAutoSendDelay : speechStopAutoSendDelay)
        speechAutoSendTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            guard let self, !Task.isCancelled else { return }
            self.speechAutoSendTask = nil
            guard self.isSessionActive, !self.privacyFilter.isPaused else { return }
            self.flushDictatedPromptIfReady()
        }
    }

    private func extendSpeechAutoSendOnActiveSpeechIfNeeded() {
        guard isSessionActive,
              !privacyFilter.isPaused,
              speechAutoSendTask != nil,
              !lastAutoSendIsFinal,
              flushableDictatedPrompt() != nil else {
            return
        }
        let elapsedSinceChange = Date().timeIntervalSince(lastTranscriptChangedAt)
        guard elapsedSinceChange < maxSpeechEnergyExtensionDelay else {
            return
        }
        scheduleSpeechAutoSend(isFinal: false)
    }

    private func flushableDictatedPrompt() -> String? {
        let trimmed = overlayStore.dictationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !lastAppliedDictationText.isEmpty,
              overlayStore.dictationText == lastAppliedDictationText else {
            return nil
        }
        return trimmed
    }

    private func flushDictatedPromptIfReady() {
        guard let prompt = flushableDictatedPrompt() else { return }
        sendTextPrompt(prompt)
    }

    private func startSpeechRecognitionIfActive() async {
        guard isSessionActive, !privacyFilter.isPaused else {
            isStartingSpeechRecognition = false
            return
        }
        isStartingSpeechRecognition = true
        if permissionsManager.speechRecognition == .notDetermined {
            let app: NSApplication? = NSApp
            app?.activate(ignoringOtherApps: true)
        }
        await speechManager.start()
        permissionsManager.refresh()
        isStartingSpeechRecognition = false
        guard isSessionActive else { return }
        if !speechManager.isListening {
            isUsingSidecarAudioFallback = true
            if let speechError = speechManager.lastError {
                surfaceSpeechErrorOnce(speechError)
            }
        } else {
            isUsingSidecarAudioFallback = false
        }
    }

    private func handleFallbackInputTranscript(_ message: InputTranscriptMessage) {
        guard isSessionActive, isUsingSidecarAudioFallback else { return }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if message.isFinal {
                commitPendingFallbackUserTranscriptIfNeeded()
            }
            return
        }

        if pendingFallbackUserTranscript.isEmpty {
            pendingFallbackUserTranscript = trimmed
        } else if !pendingFallbackUserTranscript.hasSuffix(trimmed) {
            let separator = message.text.first?.isWhitespace == true || pendingFallbackUserTranscript.last?.isWhitespace == true ? " " : " "
            pendingFallbackUserTranscript += separator + trimmed
        }
        applyLiveDictationTranscript(pendingFallbackUserTranscript)

        if message.isFinal {
            commitPendingFallbackUserTranscriptIfNeeded()
        }
    }

    private func commitPendingFallbackUserTranscriptIfNeeded() {
        let committed = pendingFallbackUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return }
        pendingFallbackUserTranscript = ""
        if overlayStore.dictationText == lastAppliedDictationText {
            overlayStore.dictationText = ""
            lastAppliedDictationText = ""
        }
        isStreamingAssistantTurn = false
        overlayStore.appendChatMessage(isUser: true, text: committed)
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

    private func pauseCaptureForPrivacy() {
        speechAutoSendTask?.cancel()
        speechAutoSendTask = nil
        isStartingSpeechRecognition = false
        isStreamingAssistantTurn = false
        speechManager.stop()
        offlineSpeechManager.stopImmediately()
        audioManager.stopPlaybackImmediately()
        audioManager.stop()
    }

    private func resumeCaptureAfterPrivacy() {
        guard isSessionActive, !privacyFilter.isPaused else { return }
        permissionsManager.refresh()

        switch permissionsManager.microphone {
        case .granted:
            startAudioCapture()
            guard isSessionActive else { return }
            Task { @MainActor [weak self] in
                await self?.startSpeechRecognitionIfActive()
            }
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self, self.isSessionActive, !self.privacyFilter.isPaused else { return }
                let app: NSApplication? = NSApp
                app?.activate(ignoringOtherApps: true)
                await self.permissionsManager.requestMicrophone()
                guard self.isSessionActive, !self.privacyFilter.isPaused else { return }
                guard self.permissionsManager.microphone == .granted else {
                    self.surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
                    self.stopSession()
                    return
                }
                self.startAudioCapture()
                guard self.isSessionActive else { return }
                await self.startSpeechRecognitionIfActive()
            }
        case .denied:
            surfaceAudioErrorOnce("Microphone permission denied in System Settings > Privacy & Security.")
            stopSession()
            return
        }

        if isSessionActive && !privacyFilter.isPaused && overlayStore.hudState != .listening {
            overlayStore.apply(HudStateMessage(
                state: .listening,
                transcriptSnippet: "Listening… (Control+Option to stop)"
            ))
        }
    }

    nonisolated internal static func normalizedEchoComparisonText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated internal static func isLikelyAssistantEcho(
        transcript: String,
        recentAssistantText: String,
        lastAssistantActivityAt: Date,
        now: Date = Date()
    ) -> Bool {
        guard lastAssistantActivityAt != .distantPast,
              now.timeIntervalSince(lastAssistantActivityAt) <= 2.5,
              !recentAssistantText.isEmpty else {
            return false
        }
        let normalizedTranscript = normalizedEchoComparisonText(transcript)
        let wordCount = normalizedTranscript.split(separator: " ").count
        guard normalizedTranscript.count >= 6 || wordCount >= 2 else {
            return false
        }
        return recentAssistantText.contains(normalizedTranscript)
    }

    private func sendScreenContextIfConnected(_ message: ScreenContextMessage) async {
        guard isSessionActive, webSocketClient.connectionState == .connected else { return }
        overlayStore.triggerCapturePulse()
        try? await webSocketClient.send(message)
    }
}
