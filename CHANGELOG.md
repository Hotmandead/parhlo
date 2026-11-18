# Parhlo Changelog

All completed engineering phases, builds, and architectural milestones achieved prior to the Phase 6–8 Interactive Teacher & UX Evolution roadmap.

---

## [v0.5.0] — Phase 5: Apple Native Intelligence Upgrades
### Added
- **Vision Shape & Document Grounding (`VisionGrounder.swift`, `AXInspector.isSparseTree`, `schemas.py`, `grounding.py`):**
  - Added `VNDetectRectanglesRequest` fallback (`detected_rects`) for applications with sparse or empty `AXUIElement` accessibility trees.
  - Added structured `DocumentContext` extraction (`title`, `paragraphs`, `tables`) from sanitized on-device OCR text, with optional `#available(macOS 26.0, *)` `RecognizeDocumentsRequest` support.
  - Extended `grounding.py` with `refine_with_detected_rects` IoU + center-containment snapping when `AXUIElement` matches are unavailable.
- **On-Device Semantic Privacy (`SemanticPrivacyClassifier.swift`):**
  - Added `HeuristicSemanticPIIClassifier` and optional Apple `FoundationModels` (`LanguageModelSession`) semantic PII line classification with a 512-entry LRU cache (`SemanticPIICache`) and `400ms` bounded timeout in `VisionRedactor`.
- **Offline Assistant & Local Speech Fallback (`OfflineAssistantEngine.swift`, `OfflineSpeechManager.swift`):**
  - Added on-device `FoundationModels` + deterministic keyword-grounded screen Q&A fallback paired with `AVSpeechSynthesizer` when disconnected from the Docker sidecar.
  - Added `Phase5IntelligenceTests.swift` verifying Vision grounding, semantic PII redaction, and offline Q&A.

---

## [v0.4.0] — Phase 4: Full-Duplex Audio, On-Device Speech, Notch UI & E2E
### Added
- **Hardware Echo-Cancelled Audio Engine (`AudioEngineManager.swift`):**
  - Implemented `AVAudioEngine` full-duplex voice I/O on a dedicated `AudioGraphWorker` serial queue with `setVoiceProcessingEnabled(true)` (`AUVoiceIO`) hardware acoustic echo cancellation and `1.4s` watchdog fallback.
  - Added 16 kHz mono PCM capture tap, 24 kHz `AVAudioPlayerNode` voice playback, instant `stopPlaybackImmediately()` on `barge_in`, and `PlaybackTapGate` anti-feedback gating (3 sustained frames `>= 0.065` RMS + `0.35s` post-playback tail holdoff).
- **Live On-Device Speech-to-Text (`SpeechRecognitionManager.swift`):**
  - Integrated `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` normalizing multi-channel `VPAUAggregateAudioDevice` buffers to mono Float32 PCM.
  - Added automatic `TextUpMessage` dispatch on speech stop (`1.15s` silence / `0.15s` on `isFinal`, extended up to `2.2s` during sustained speech energy) and assistant echo suppression (`isLikelyAssistantEcho`).
- **Global Voice Hotkey (`GlobalHotkeyManager.swift`):**
  - Bound `Control+Option` (`⌃⌥`) smart tap-to-toggle and hold-to-speak modifier monitoring across global and local `NSEvent` monitors.
- **Interactive Top-Center Notch Assistant (`NotchPanelWindowController.swift`, `NotchAssistantView.swift`):**
  - Built non-activating `NotchPanel` expanding on hover or click into a 540×440 voice/chat drawer with live dictation, mic RMS meter, mute/barge-in controls, and chat transcript history.
- **App Coordinator & Settings (`AppCoordinator.swift`, `SettingsView.swift`, `ParhloApp.swift`):**
  - Wired end-to-end session lifecycle, 5-tab dark Settings window, and 51+ Swift unit tests across 6 suites (`AudioHotkeyAndCoordinatorTests`, `NotchHoverTests`, `SpeechAndTextBridgeTests`).

---

## [v0.3.0] — Phase 3: ScreenCaptureKit, Local Vision Redaction & WebSocket Bridge
### Added
- **Privacy Filter (`PrivacyFilter.swift`):**
  - Automatic session pausing and overlay clearing when password managers or excluded bundle IDs (`1Password`, `Bitwarden`, `Keychain Access`, `Terminal`, etc.) become frontmost via `NSWorkspace`.
- **On-Device OCR Redaction (`VisionRedactor.swift`):**
  - Pre-compression `VNRecognizeTextRequest` scanning captured frames off `@MainActor` for API keys, bearer tokens, OAuth secrets, passwords, credit cards, and SSNs, painting solid black masks over matched character ranges (and failing closed on OCR error).
- **Accessibility Hierarchy Inspector (`AXInspector.swift`):**
  - Breadth-first `AXUIElement` traversal extracting visible control roles, sanitized titles/descriptions/values (suppressing `AXSecureTextField`), and display-local pixel bounding boxes.
- **On-Demand Capture Engine (`CaptureEngine.swift`):**
  - `ScreenCaptureKit` (`SCScreenshotManager`) capture strictly capped at `<= 1 FPS` during active sessions, excluding Parhlo's own bundle ID and protected apps via `SCContentFilter` and encoding redacted frames at `0.65` JPEG quality.
- **WebSocket Client (`SidecarWebSocketClient.swift`, `WireModels.swift`):**
  - Strictly typed Swift 6 `Codable` wire models matching Python Pydantic v2 schemas over `ws://127.0.0.1:8765`, backed by `CaptureAndBridgeTests.swift`.

---

## [v0.2.0] — Phase 2: Native macOS Click-Through Overlay & Onboarding
### Added
- **Click-Through Overlay Window (`OverlayWindowController.swift`, `OverlayStateStore.swift`, `OverlayModels.swift`):**
  - Borderless, non-activating `OverlayWindow` (`ignoresMouseEvents = true`, `sharingType = .none`, `.screenSaver` level) with top-left-to-AppKit coordinate conversion.
- **GPU Vector Annotation Renderer (`VectorAnnotationLayerView.swift`, `OverlayCanvasView.swift`):**
  - Core Animation `CAShapeLayer` rendering for `highlight_region` (rounded glow boxes + optional pulsing spotlight rings), `point_arrow` (curved quadratic Bézier arrows + pill labels), and SwiftUI `StepCalloutCardView` glassmorphic cards.
- **TCC Permissions & Onboarding (`PermissionsManager.swift`, `PermissionsOnboardingView.swift`):**
  - Live status checks and deep-links for Screen Recording (`CGPreflightScreenCaptureAccess`), Accessibility (`AXIsProcessTrusted`), Microphone (`AVCaptureDevice`), and Speech Recognition.

---

## [v0.1.0] — Phase 1: Dockerized Python 3.12 Gemini Live Sidecar
### Added
- **Containerized Sidecar Stack (`Dockerfile`, `compose.yaml`, `.dockerignore`, `.env.example`):**
  - Pinned `python:3.12-slim` multi-stage container with isolated `/opt/venv`, `watchfiles` hot-reload, and Dockerized `pytest` suite.
- **Wire Protocol & Grounding (`schemas.py`, `grounding.py`):**
  - Strict Pydantic v2 discriminated unions (`UpstreamMessage`, `DownstreamMessage`), `0–999` `[ymin, xmin, ymax, xmax]` coordinate denormalization, and `AXUIElement` IoU + label-similarity bounding-box snapping.
- **Non-Blocking Visual Tools & Live Session (`tools.py`, `tool_dispatcher.py`, `live_session.py`, `server.py`):**
  - `gemini-3.8-live` bidirectional session manager with `NON_BLOCKING` function declarations (`highlight_region`, `point_arrow`, `show_step_callout`, `clear_annotations`), context window compression, session resumption handles, `GoAway` proactive reconnect, and immediate VAD barge-in (`BargeInMessage`).
