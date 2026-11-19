# Parhlo Workspace Guide for AI Agents

Parhlo is a two-process macOS screen-aware AI companion communicating over a local WebSocket (`ws://127.0.0.1:8765`).

## Repository Layout
- `agent-sidecar/` — Dockerized Python 3.12 Gemini Live API sidecar (`gemini-3.8-live`) with `watchfiles` live reload. See `agent-sidecar/AGENTS.md` and `agent-sidecar/ARCHITECTURE.md`.
- `macos-app/` & `Parhlo.xcworkspace` — Native Swift 6 macOS app (`ScreenCaptureKit`, `AXUIElement`, `Vision`, `AVAudioEngine`, `Speech`, `FoundationModels`, `CAShapeLayer`/SwiftUI overlay & Notch Assistant Drawer). See `macos-app/AGENTS.md` and `macos-app/ARCHITECTURE.md`.
- `README.md`, `SETUP.md` & `implementation_plan.md` — Architecture roadmap and local Xcode/Docker setup commands.

## Global Invariants
1. **Single Wire Contract:** `agent-sidecar/src/sidecar/schemas.py` (`UpstreamMessage` / `DownstreamMessage`) is the source of truth, mirrored in `macos-app/Packages/CompanionCore/Sources/CompanionCore/Models/WireModels.swift` and `OverlayModels.swift`. Any field, action, or state change must update both Python Pydantic v2 models and Swift `Codable` models plus unit tests in the same change.
2. **Privacy by Default:** Never bypass on-device `VisionRedactor` fail-closed OCR masking, `AXInspector` `AXSecureTextField` suppression, `SCContentFilter` self-exclusion, or `PrivacyFilter` bundle-ID exclusions. Capture is strictly on-demand (`<= 1 FPS`), never continuous background recording.
3. **Confirmed Product Defaults:**
   - Default model: `gemini-3.8-live` (configurable via `GEMINI_LIVE_MODEL` in `.env`).
   - Global voice hotkey: `Control+Option` (`⌃⌥`) and top-center **Notch Assistant Drawer** (`NotchPanelWindowController` / `NotchAssistantView`) with live `SFSpeechRecognizer` dictation into the input box, automatic send on speech stop, hardware AEC + `PlaybackTapGate` anti-feedback, and an `NSStatusItem` menu bar controller (left-click toggles drawer, right-click opens menu).
4. **Git Branch Architecture & Safety:**
   - Never commit `.env`, API keys, or credentials. Keep `.gitignore` updated and use Conventional Commits (`feat:`, `fix:`, `refactor:`, `test:`, `chore:`).
   - Use the 4-branch topology: `main` (release), `dev` (integration), `feat/macos-app` (Swift/macOS app work), and `feat/agent-sidecar` (Python sidecar/Docker work).
5. **Verification & Fast Manual Testing:** Always spawn a background subagent to run Swift unit tests (`cd macos-app/Packages/CompanionCore && swift test`) and Docker sidecar tests (`docker compose run --rm sidecar pytest -v`) so the main agent can immediately run `xcodebuild` / launch `Parhlo.app` for manual testing without blocking. See `.agents/skills/verify-parhlo/SKILL.md`.
