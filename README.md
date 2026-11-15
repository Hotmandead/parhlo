# Parhlo

Screen-Aware macOS AI Companion with Live Visual Explanations.

A native macOS screen-aware AI assistant optimized for Apple Silicon (`arm64-apple-macosx`) that perceives on-screen content in real time via `ScreenCaptureKit` and `AXUIElement`, redacts sensitive on-screen text locally with Apple `Vision`, converses naturally via low-latency bidirectional voice using the Gemini Live API (`gemini-3.8-live`), and draws live, click-through animated visual explanations directly over macOS applications without stealing focus.

## Implementation Status

| Component | Status | Notes |
| :--- | :--- | :--- |
| **Environment & API Setup** | Completed | `.venv` (`google-genai==3.3.0`), `.env.example`, local `.env` |
| **Live API Prototype** | Completed | `live_prototype.py` (16 kHz mic, 24 kHz playback, 1 FPS screen/image, `NON_BLOCKING` tool call) |
| **Phase 1: Docker & Python Sidecar** | Completed | `Dockerfile`, `compose.yaml`, `.dockerignore`, `agent-sidecar/` (`6 passed` in Docker `pytest`) |
| **Phase 2: Native macOS Overlay** | Pending | `macos-app/` (`Parhlo.xcodeproj`, `PermissionsManager`, `OverlayWindowController`, `CAShapeLayer` + SwiftUI) |
| **Phase 3: Capture, Vision Redaction & Bridge** | Pending | `PrivacyFilter`, `VisionRedactor`, `AXInspector`, `CaptureEngine`, `SidecarWebSocketClient` |
| **Phase 4: Bidirectional Audio & Hotkey** | Pending | `AudioEngineManager` (`AVAudioEngine`), `GlobalHotkeyManager`, `AppCoordinator`, E2E loopback test |

## Quick Start (Current Prototype & Sidecar)

1. **Copy env template and add your key** (from https://aistudio.google.com/apikey):
   ```bash
   cp .env.example .env
   ```
2. **Run the standalone Live API prototype:**
   ```bash
   .venv/bin/python live_prototype.py
   ```
3. **Build and test the Dockerized Python sidecar:**
   ```bash
   docker compose build
   docker compose run --rm sidecar pytest -v
   docker compose up
   ```
