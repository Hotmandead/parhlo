# Parhlo — Product Brief (LLM Context Pack)

> **Purpose of this file:** A self-contained summary of what Parhlo is, what already exists, and what is being built next. Paste it into any LLM as context before asking for design, code, copy, or review help. Source of truth for details: `implementation_plan.md`, `CHANGELOG.md`, `agent-sidecar/src/sidecar/schemas.py`.

---

## 1. One-liner

**Parhlo is a native macOS AI tutor that sees your screen, listens to your voice, and teaches you like a human teacher sitting next to you: it talks, points, underlines, circles, and annotates directly over any app.** The name comes from Urdu/Hindi *"parh lo"*, meaning "read it" or "study it".

## 2. Vision

Most AI assistants live in a chat box and describe things in words. Parhlo works **on top of whatever you are already looking at**, like a PDF, textbook, article, slide deck, code editor, or complex app UI. You point at something with your mouse and ask out loud. Parhlo explains it aloud in real time and marks up the screen as it talks: it underlines the heading, highlights key phrases, brackets the paragraph, glides a pointer across the content, and leaves short summary notes in the margin.

**North-star experience: "Circle & Ask"**
1. You are reading a PDF chapter. Hold `⌃⌥` (Control+Option) and **circle a heading and paragraph with your mouse**.
2. Say: *"Explain this section to me like a teacher."*
3. A glowing lasso trail confirms what Parhlo saw. Then, while it explains aloud:
   - it **underlines the heading** with an animated pen stroke snapped to the exact words,
   - it **marker-highlights 1–3 key terms** as it says each one,
   - it **brackets the paragraph** in the margin and adds a **summary card** beside it (never covering the text),
   - a **Teacher Pointer** (a virtual laser cursor) glides from heading → key points → figure in sync with its voice.
4. You interrupt at any time by speaking (barge-in). You can click a margin pin to ask for *"Give me an example"*, *"Explain simpler"*, or *"Quiz me"*.

## 3. Target users & use cases

- **Students and self-learners** reading PDFs, textbooks, papers, and articles.
- **Professionals** learning a complex app UI ("where do I click to do X?").
- **Developers** who want code or docs on screen walked through visually.
- Core jobs: explain this section, define this term, walk me through this diagram or formula, show me where to click, summarize this page, quiz me.

## 4. Product principles (non-negotiable)

1. **Privacy by default.**
   - Screen capture happens only during an active session and only on demand, at ≤ 1 FPS. Parhlo never records in the background.
   - Secrets (API keys, tokens, passwords, credit cards, SSNs, semantic PII) are **blacked out on-device** with Apple Vision OCR before any frame leaves the Mac. If OCR fails, nothing is sent (fail closed).
   - Sessions pause automatically, and overlays clear, when a password manager or other excluded app (1Password, Bitwarden, Keychain Access, Terminal, etc.) comes to the front.
   - Parhlo's own windows are excluded from capture and screen sharing.
2. **Never steal focus.** The overlay is click-through and non-activating, so your app keeps the keyboard and mouse.
3. **Annotations must never hide the text being read.** Use underlines, multiply-blended highlighter bands, margin brackets, and margin cards. No opaque boxes over text.
4. **Voice-first, low-latency, interruptible.** Full-duplex audio with hardware echo cancellation. Speaking over Parhlo stops its playback immediately.
5. **The user is in control.** Parhlo waits for an explicit request and does not comment on its own. OS cursor takeover is opt-in and gives control back the instant you touch the mouse or trackpad.
6. **Native and fast on everyday Apple Silicon Macs**, including 8 GB machines.

## 5. Architecture (two processes)

```
┌──────────────────────────── macOS App (Swift 6, native) ─────────────────────────────┐
│ Menu bar (NSStatusItem) + Notch drawer UI · Global hotkey ⌃⌥ (tap = toggle, hold = talk)│
│ ScreenCaptureKit (≤1 FPS) → PrivacyFilter → VisionRedactor (on-device OCR masking)      │
│ AXUIElement inspector (UI control bounds) · VisionGrounder (rect/document detection)    │
│ AVAudioEngine full-duplex voice (AEC) · SFSpeechRecognizer dictation                    │
│ Click-through Overlay (CAShapeLayer + SwiftUI): highlights, arrows, step cards          │
│ Offline fallback: Apple FoundationModels Q&A + AVSpeechSynthesizer                      │
└───────────────▲─────────────────────────── WebSocket ws://127.0.0.1:8765 ──────────────┘
                │  JSON messages (Pydantic v2 ⇄ Swift Codable; one shared contract)
┌───────────────▼──────────── agent-sidecar (Python 3.12, Docker) ───────────────────────┐
│ Gemini Live session (`gemini-3.8-live`): voice + vision, VAD barge-in, resumption,     │
│ context compression · Non-blocking visual tool calls · Grounding: snaps model's 0–999  │
│ coordinates to real AX element / detected-rect bounds (IoU + label similarity)          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

**Wire contract today** (`schemas.py` ⇄ `WireModels.swift`). Any change must update both sides and their tests together.
- **Upstream (app → sidecar):** `session_control` (start/stop/barge_in_manual), `screen_context` (redacted JPEG, screen size/scale, `ax_elements`, `detected_rects`, `document_context`, frontmost bundle ID), `audio_up` (16 kHz PCM), `text_up`.
- **Downstream (sidecar → app):** `draw_command` (`highlight_region` | `point_arrow` | `show_step_callout` | `clear_annotations`, with pixel rect/points/label/explanation/color/style), `audio_down` (24 kHz PCM), `barge_in`, `hud_state` (idle/listening/thinking/drawing/privacy_paused), `input_transcript`.

## 6. Status: what exists (Phases 1–5 ✅)

| Phase | Delivered |
| :--- | :--- |
| 1. Sidecar | Dockerized Gemini Live sidecar, strict wire schema, coordinate grounding, non-blocking draw tools, session resumption/GoAway reconnect, VAD barge-in |
| 2. Overlay | Click-through overlay window, GPU vector annotations (glow boxes, curved arrows, glass step cards), TCC permission onboarding |
| 3. Capture & privacy | ScreenCaptureKit on-demand capture, bundle-ID privacy pause, on-device OCR secret masking, Accessibility tree inspector, WebSocket bridge |
| 4. Voice & UI | Full-duplex echo-cancelled audio, on-device dictation, `⌃⌥` hotkey, hover-to-expand Notch assistant drawer (chat + live dictation + mic meter), 5-tab Settings, 51+ Swift tests |
| 5. Apple intelligence | Vision rectangle/document grounding for apps with poor accessibility trees, FoundationModels semantic PII classifier, offline Q&A + local TTS fallback |

**Current gap:** Parhlo is good at pointing at *UI controls* but **blind to document text layout**. OCR finds exact positions for every line and word, but only the flattened text is forwarded. The model therefore has to guess coordinates for headings and paragraphs from a compressed JPEG. Parhlo also ignores mouse gestures and can only draw boxes and arrows.

## 7. Roadmap: desired features (Phases 5.5–10c, Pending Review Gates G1–G7 🚧)

### Phase 5.5: Platform baseline & quick wins (Gate G1)
- Configure Gemini Live `media_resolution` (`HIGH` default) and keep static prompt prefixes APC-stable.
- Keep full frames at logical points (`Q=80`) while capturing focused ROI crops at **backing-pixel (Retina) resolution**, gated by a lightweight Laplacian blur check to skip mid-scroll frames.

### Phase 6: Text-aware screen understanding (Gate G2)
- Single-pass redaction-first OCR: keep **line and word geometry** (`ocr_blocks`: stable `block_id`, text, pixel bounds, structural `kind`, `in_focus_rect`) derived from `VisionRedactor`'s single pass *after* PII masking. Review unifying onto `RecognizeDocumentsRequest` on macOS 26+ with `VNRecognizeTextRequest` heuristics fallback on macOS 14–15.
- Sidecar `grounding.py`: deterministic `block_id` + phrase snapping, with `refine_with_ocr_blocks` fuzzy text matching as fallback; fall back to AX bounds for controls and detected rects for icons and diagrams.
- Perceptual-drift guard: tag frames and `draw_command`s with monotonic `frame_id` so stale annotations are discarded after scrolling or window switches.
- Feed `[OCR Layout & Headings]` inside `[UNTRUSTED SCREEN TEXT]` delimiters at the tail of context.

### Phase 7: Mouse gestures in, teacher pointer out (Gate G3)
- `MouseGestureTracker`: while `⌃⌥` or a session is active, detect **circular spins** (≥ 270° winding or a closed loop within 1.5 s), back-and-forth "underline" motions, and dwell. Render a neon lasso trail on the excluded overlay (never baked into captured pixels) and send `user_focus_rect` + `cursor_point` + Retina `roi_jpeg_b64`.
- `TeacherPointerController`:
  - **Mode 1 (default):** a virtual "🎓 Parhlo" laser cursor on the overlay that glides with spring animation along waypoints.
  - **Mode 2 (opt-in, "Take the Mouse", subject to Gate G3):** move-only guidance of the real macOS cursor along Bézier paths (never clicks/types, clamped to display bounds, disabled on excluded privacy apps, instant hardware breakaway when the user moves the mouse).

### Phase 8: Expressive teacher annotations
- New draw actions: **`underline_text`** (solid / double / wavy / marker highlighter with multiply blend), **`bracket_region`** (margin bracket + note), **`circle_region`** (hand-drawn ellipse), **`move_pointer`** (waypoints, `block_id`, or text anchors).
- Anti-collision layout so labels, brackets, and cards never overlap each other or cover the text. Older annotations fade to 35% opacity so the eye follows the current sentence.

### Phase 9: Teacher persona & study mode (Gate G4)
- System prompt choreography: **underline heading + move pointer → bracket paragraph + marker key terms as spoken → margin summary card**. Visual strokes stay in sync with speech, with prompt-injection delimiters around screen text.
- Clickable margin pins on cards for quick follow-ups: example, simpler, quiz me.
- Local dictation upgrade (Gate G4): `SpeechAnalyzer` / `SpeechTranscriber` on macOS 26+ with `SFSpeechRecognizer` fallback on macOS 14–15.

### Phase 10: Hybrid edge + cloud intelligence (10a / 10b / 10c — Gates G5–G7)
- **10a — On-device LLM & memory governance (native Metal, never in Docker):** **Gemma 4 E2B** (~2.58 GB) via LiteRT-LM Swift + **FunctionGemma** (~289 MB) for intent/triage, with **Apple Foundation Models** (`SystemLanguageModel`, macOS 26+) as zero-download fallback (Gemma 3n demoted to spike baseline; optional Gemma 4 E4B on 16 GB+ Macs; in-process MLX Swift as contingency). Enforce `< 2.7 GB` working set on 8 GB Macs, lazy load, idle unload, and `DispatchSource` memory-pressure eviction.
- **10b — Live coexistence, router & deep reasoning:** Tier 1 runs **alongside** `gemini-3.8-live` (never intercepting full-duplex voice) for `< 300 ms` local visual anchoring, offline Q&A (`"Answered offline"` badge), and triage using structured confidence proxies (not token entropy). Complex tasks (multi-page synthesis, math, code, quizzes) escalate to a sidecar `ReasoningRouter` (**Gemini Pro** default, optional **OpenAI API**, optional Document AI/Cloud Vision) via `reasoning_request` / `reasoning_result` (`tier: "live" | "deep"`) and `"escalating"` HUD state.
- **10c — On-demand distribution & integrity:** Developer ID / notarized downloads to Application Support on first use, verified against a signed manifest, SHA-256 checksum, and remote version blocklist.
- **Out of scope / deferred:** `PaliGemma 2`, Python `MLX-LM` server on `:8080`, zero-copy `MTLTexture`→`TensorBuffer`, `Moonshine Voice` / `Kokoro-82M`, `UI-TARS-7B` / `Qwen2.5-VL-7B`, `EmbeddingGemma 2`, `DiffusionGemma`, and `gpt-oss-120b/20b`.

## 8. Fixed decisions & constraints

- **Platform:** macOS 14+, Apple Silicon (arm64), Swift 6 strict concurrency, SwiftPM package `CompanionCore` + Xcode app target `Parhlo`, non-sandboxed Developer ID distribution.
- **Sidecar:** Python 3.12, Pydantic v2, `google-genai`, always run in Docker (`docker compose up --build`); tests run in the container. On-device ML must **not** go in Docker (Docker on macOS has no Metal or Neural Engine access).
- **Defaults:** model `gemini-3.8-live` (`GEMINI_LIVE_MODEL`), hotkey `⌃⌥`, localhost WebSocket port `8765`.
- **Coordinates:** the model outputs `[ymin, xmin, ymax, xmax]` normalized to 0–999. The sidecar converts them to top-left-origin pixels and snaps them to real element bounds.
- **Permissions (TCC):** Screen Recording, Accessibility, Microphone, Speech Recognition.
- **Engineering & Git hygiene:** never commit `.env` or keys; use Conventional Commits; land cross-process wire contracts on `dev` first; run parallel macOS and sidecar agent worktrees off `feat/macos-app` and `feat/agent-sidecar`, merge tested code to component branches, verify E2E on `dev`, then promote polished releases to `main`.

## 9. Glossary

| Term | Meaning |
| :--- | :--- |
| Sidecar | The Dockerized Python process that holds the Gemini Live session |
| Overlay | The full-screen, click-through, transparent window where annotations are drawn |
| Notch drawer | The top-center pill UI that expands into chat, dictation, and controls |
| Grounding | Converting a model's approximate coordinates into exact on-screen bounds |
| AX elements | macOS Accessibility tree nodes (buttons, fields) with screen bounds |
| OCR blocks | Vision-detected text lines/words with pixel bounds (Phase 6) |
| ROI | Region of interest: the area the user circled with the mouse |
| Barge-in | The user speaking over Parhlo, which immediately stops its audio |
| Teacher Pointer | The virtual laser cursor Parhlo moves while explaining |
