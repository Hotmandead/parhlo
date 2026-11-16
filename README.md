# Parhlo

Screen-Aware macOS AI Companion with Live Visual Explanations.

A native macOS screen-aware AI assistant optimized for Apple Silicon (`arm64-apple-macosx`) that perceives on-screen content on demand (`<= 1 FPS`) via `ScreenCaptureKit` and `AXUIElement`, redacts sensitive on-screen text locally with Apple `Vision`, converses naturally via low-latency full-duplex voice (`Control+Option`, `AVAudioEngine` Voice Processing AEC + `gemini-3.8-live`), and draws live, click-through animated visual explanations directly over macOS applications without stealing focus.

## Implementation Status

| Component | Status | Notes |
| :--- | :--- | :--- |
| **Environment & API Setup** | Completed | `.env.example`, local `.env` |
| **Phase 1: Docker & Python Sidecar** | Completed | `Dockerfile`, `compose.yaml`, `.dockerignore`, `agent-sidecar/` (`pytest` in Docker) |
| **Phase 2: Native macOS Overlay** | Completed | `macos-app/` (`Parhlo.xcodeproj`, `PermissionsManager`, `OverlayWindowController`, `CAShapeLayer` + SwiftUI) |
| **Phase 3: Capture, Vision Redaction & Bridge** | Completed | `PrivacyFilter`, `VisionRedactor`, `AXInspector`, `CaptureEngine`, `SidecarWebSocketClient` |
| **Phase 4: Bidirectional Audio, Hotkey & E2E** | Completed | `AudioEngineManager` (`AVAudioEngine` AEC), `GlobalHotkeyManager` (`Control+Option`), `AppCoordinator`, `SettingsView`, E2E check |
| **Phase 5: Apple Native Intelligence Upgrades** | Completed | `VisionGrounder` (`VNDetectRectanglesRequest` + `RecognizeDocumentsRequest`), `SemanticPrivacyClassifier` (`FoundationModels` + LRU cache), `OfflineAssistantEngine` + `OfflineSpeechManager` (`AVSpeechSynthesizer`) |

## Quick Start

1. **Copy env template and add your key** (from https://aistudio.google.com/apikey):
   ```bash
   cp .env.example .env
   ```
2. **Build, test, and start the Dockerized Python sidecar (`ws://127.0.0.1:8765`):**
   ```bash
   docker compose build
   docker compose run --rm sidecar pytest -v
   docker compose up -d
   ```
3. **Test and run the native macOS app (`macos-app/`):**
   ```bash
   cd macos-app/Packages/CompanionCore
   swift build
   swift test
   ```
   Then open `Parhlo.xcworkspace` (at repo root) in Xcode and press **Run (`⌘R`)** or **Test (`⌘U`)**.
4. **Grant TCC Permissions & Speak:**
   - Click the Parhlo menu bar icon → **Settings & Permissions…** to grant **Screen Recording**, **Accessibility**, and **Microphone**.
   - Press **`Control+Option` (`⌃⌥`)** (tap to toggle, or hold to speak) over any macOS app—or choose **Start Voice Session (`⌃⌥`)** / **Demo Visual Annotations** from the menu bar.
