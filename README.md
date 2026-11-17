# Parhlo

Screen-Aware macOS AI Companion with Live Visual Explanations.

A native macOS screen-aware AI companion optimized for Apple Silicon (`arm64-apple-macosx`) that perceives on-screen content on demand (`<= 1 FPS`) via `ScreenCaptureKit` and `AXUIElement`, redacts sensitive on-screen text locally with Apple `Vision`, interacts through a hover-to-expand **Notch Assistant Drawer** (Voice & Chat tabs, `SFSpeechRecognizer` live dictation auto-send with assistant-echo defense, and `AVAudioEngine` Voice Processing AEC + `gemini-3.8-live`), falls back to on-device Q&A + `AVSpeechSynthesizer` when offline, and draws live, click-through animated visual explanations directly over macOS applications without stealing focus.

## Implementation Status

| Component | Status | Notes |
| :--- | :--- | :--- |
| **Environment & API Setup** | Completed | `.env.example`, local `.env` |
| **Phase 1: Docker & Python Sidecar** | Completed | `Dockerfile`, `compose.yaml`, `.dockerignore`, `agent-sidecar/` (`ARCHITECTURE.md`, `watchfiles` auto-reload, `pytest` in Docker) |
| **Phase 2: Native macOS Overlay** | Completed | `Parhlo.xcworkspace`, `macos-app/` (`ARCHITECTURE.md`, `Parhlo/ParhloApp.swift`, `Packages/CompanionCore`, `PermissionsManager`, `OverlayWindowController`, `NotchPanelWindowController`, `CAShapeLayer` + SwiftUI) |
| **Phase 3: Capture, Vision Redaction & Bridge** | Completed | `PrivacyFilter`, `VisionRedactor`, `AXInspector`, `CaptureEngine`, `SidecarWebSocketClient` |
| **Phase 4: Bidirectional Audio, Hotkey & E2E** | Completed | `AudioEngineManager` (`AVAudioEngine` AEC + `PlaybackTapGate` anti-feedback), `SpeechRecognitionManager` (live dictation auto-send + echo defense), `GlobalHotkeyManager` (`Control+Option`), `NotchAssistantView`, `AppCoordinator`, `SettingsView`, E2E check |
| **Phase 5: Apple Native Intelligence Upgrades** | Completed | `VisionGrounder` (`VNDetectRectanglesRequest` + sanitized OCR / optional macOS 26 `RecognizeDocumentsRequest`), `SemanticPrivacyClassifier` (`HeuristicSemanticPIIClassifier` + 512-entry `SemanticPIICache`, optional `FoundationModels`), `OfflineAssistantEngine` + `OfflineSpeechManager` (`AVSpeechSynthesizer`) |

## Quick Start

1. **Copy env template and add your `GEMINI_API_KEY`** (from https://aistudio.google.com/apikey):
   ```bash
   cp .env.example .env
   # Edit .env and set GEMINI_API_KEY=your_key_here
   ```
2. **Build, test, and start the Dockerized Python sidecar (`ws://127.0.0.1:8765`):**
   ```bash
   docker compose build
   docker compose run --rm sidecar pytest -v
   docker compose up -d
   ```
   > **Live Reloading:** `compose.yaml` bind-mounts `./agent-sidecar` and runs `watchfiles` on `/app/agent-sidecar/src`, so edits to Python files reload automatically in the running container without rebuilding. Only run `docker compose up -d --build` when changing `Dockerfile` or `agent-sidecar/pyproject.toml` dependencies.
3. **Test and run the native macOS app (`macos-app/`):**
   ```bash
   cd macos-app/Packages/CompanionCore
   swift build
   swift test
   ```
   Then open `Parhlo.xcworkspace` (at repo root) in Xcode and press **Run (`⌘R`)** or **Test (`⌘U`)**.
4. **Grant TCC Permissions & Speak:**
   - Right-click the Parhlo menu bar icon → **Settings & Permissions…** (or hover the top-center **Notch Pill** and click **⚙**) to grant all four TCC permissions: **Screen Recording**, **Accessibility**, **Microphone**, and **Speech Recognition**.
   - Press **`Control+Option` (`⌃⌥`)** (tap to toggle, or hold to speak) over any macOS app, hover the top-center **Notch Pill** (or left-click the menu bar icon) to open the **Notch Assistant Drawer** for live dictation/chat (auto-sends when speech pauses and falls back on-device when disconnected), or right-click the menu bar icon for **Start Voice Session (`⌃⌥`)** / **Demo Visual Annotations**.

## Git Branch Architecture

- `main` (`origin/main`) — Stable release baseline.
- `dev` (`origin/dev`) — Integration branch spun off from `main`.
- `feat/macos-app` (`origin/feat/macos-app`) — Dedicated feature branch for native Swift / AppKit / SwiftUI macOS application changes (`macos-app/`).
- `feat/agent-sidecar` (`origin/feat/agent-sidecar`) — Dedicated feature branch for Dockerized Python Gemini Live sidecar changes (`agent-sidecar/`, `Dockerfile`, `compose.yaml`).
