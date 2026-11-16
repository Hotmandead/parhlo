# Parhlo Workspace Guide for AI Agents

Parhlo is a two-process macOS screen-aware AI companion communicating over a local WebSocket (`ws://127.0.0.1:8765`).

## Repository Layout
- `agent-sidecar/` — Dockerized Python 3.12 Gemini Live API sidecar (`gemini-3.8-live`). See `agent-sidecar/AGENTS.md`.
- `macos-app/` — Native Swift 6 macOS app (`ScreenCaptureKit`, `AXUIElement`, `Vision`, `AVAudioEngine`, `CAShapeLayer`/SwiftUI overlay). See `macos-app/AGENTS.md`.
- `implementation_plan.md` & `SETUP.md` — Architecture roadmap and local Xcode/Docker setup commands.

## Global Invariants
1. **Single Wire Contract:** `agent-sidecar/src/sidecar/schemas.py` (`UpstreamMessage` / `DownstreamMessage`) is the source of truth. Any field, action, or state change must update both Python Pydantic v2 models and Swift `Codable` models plus unit tests in the same change.
2. **Privacy by Default:** Never bypass on-device `VisionRedactor` OCR masking or `PrivacyFilter` bundle-ID exclusions. Capture is strictly on-demand (`<= 1 FPS`), never continuous background recording.
3. **Confirmed Product Defaults:**
   - Default model: `gemini-3.8-live` (configurable via `GEMINI_LIVE_MODEL` in `.env`).
   - Global voice hotkey: `Control+Option` (`⌃⌥`) to speak to the macOS app, plus an `NSStatusItem` menu bar controller.
4. **Secrets & Git Safety:** Never commit `.env`, API keys, or credentials. Keep `.gitignore` updated and use Conventional Commits (`feat:`, `fix:`, `refactor:`, `test:`, `chore:`).
5. **Verification:** Use `.agents/skills/verify-parhlo/SKILL.md` for end-to-end validation commands.
