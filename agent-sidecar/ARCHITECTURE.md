# Parhlo Agent Sidecar (`agent-sidecar`) Architecture

`agent-sidecar` is the Dockerized Python 3.12 service (`parhlo-sidecar` v`0.1.0`) that bridges the native macOS client (`macos-app`) over a local WebSocket (`ws://127.0.0.1:8765`) to Google's Gemini Live API (`google-genai`). It receives base64-encoded redacted screen frames, `AXUIElement` snapshots, 16 kHz PCM audio, and text prompts; manages a bidirectional Gemini Live session; resolves `NON_BLOCKING` spatial tool calls against macOS accessibility bounds; and streams 24 kHz PCM voice audio, HUD states, barge-in signals, and pixel-accurate draw commands back to macOS.

---

## Module Map

| File | Responsibility | Key Symbols |
| :--- | :--- | :--- |
| [`src/sidecar/server.py`](src/sidecar/server.py) | `websockets` server entrypoint, JSON frame validation, per-connection lifecycle | `run_server`, `handle_connection`, `UPSTREAM_ADAPTER`, `main` |
| [`src/sidecar/schemas.py`](src/sidecar/schemas.py) | Pydantic v2 wire contract (`UpstreamMessage` & `DownstreamMessage`) | `UpstreamMessage`, `DownstreamMessage`, `ScreenContextMessage`, `DrawCommandMessage`, `InputTranscriptMessage`, `AXElementBounds`, `DetectedRectBounds`, `DocumentContext` |
| [`src/sidecar/live_session.py`](src/sidecar/live_session.py) | Bidirectional Gemini Live API session lifecycle, compression/resumption, media streaming, VAD barge-in | `GeminiLiveSessionManager`, `build_live_config`, `summarize_ax_elements`, `summarize_document_context` |
| [`src/sidecar/tools.py`](src/sidecar/tools.py) | `NON_BLOCKING` Gemini `FunctionDeclaration` schemas for screen overlays | `get_overlay_tools`, `BOX_2D_SCHEMA` |
| [`src/sidecar/tool_dispatcher.py`](src/sidecar/tool_dispatcher.py) | Converts Gemini `FunctionCall` payloads into `DrawCommandMessage` + `FunctionResponse` | `resolve_tool_call` |
| [`src/sidecar/grounding.py`](src/sidecar/grounding.py) | `0–999` box denormalization and deterministic `AXUIElement` / Vision rect snapping | `denormalize_box`, `rect_center`, `compute_iou`, `refine_with_ax_elements`, `refine_with_detected_rects` |
| [`tests/test_grounding_and_schemas.py`](tests/test_grounding_and_schemas.py) | Unit tests for denormalization, AX/Vision snapping, `NON_BLOCKING` tools, schemas, and Live session lifecycle | `test_live_session_processes_tool_call_audio_and_barge_in` |

---

## End-to-End Message & Grounding Flow

```mermaid
sequenceDiagram
    autonumber
    participant Mac as macos-app
    participant WS as server.py (handle_connection)
    participant Mgr as GeminiLiveSessionManager
    participant Live as Gemini Live API (gemini-3.8-live)
    participant Disp as tool_dispatcher.py & grounding.py

    Mac->>WS: UpstreamMessage JSON (type = "session_control", action = "start_session")
    WS->>Mgr: handle_upstream(SessionControlMessage)
    Mgr->>Live: client.aio.live.connect(model, build_live_config(handle))
    Mgr-->>Mac: HudStateMessage(state="listening")

    par Continuous Multimodal Upstream
        Mac->>WS: ScreenContextMessage (jpeg_b64, ax_elements, detected_rects, document_context)
        WS->>Mgr: handle_upstream(ScreenContextMessage)
        Mgr->>Mgr: Cache _latest_screen (no periodic text turns)
        Mgr->>Live: send_realtime_input(video=Blob(image/jpeg))
    and
        Mac->>WS: AudioUpMessage (16 kHz Int16 PCM pcm_b64)
        WS->>Mgr: handle_upstream(AudioUpMessage)
        Mgr->>Live: send_realtime_input(audio=Blob("audio/pcm;rate=16000"))
    and
        Mac->>WS: TextUpMessage (text)
        WS->>Mgr: handle_upstream(TextUpMessage)
        opt Changed UI or Document context
            Mgr->>Live: send_client_content(turns=[UI/Document Context], turn_complete=False)
        end
        Mgr->>Live: send_client_content(turns=[User text], turn_complete=True)
    end

    Live-->>Mgr: session_resumption_update / go_away (proactive reconnect with handle)
    Live-->>Mgr: server_content.interrupted == True (VAD Barge-In)
    Mgr-->>Mac: BargeInMessage(reason="vad_interrupted")

    Live-->>Mgr: tool_call.function_calls (NON_BLOCKING)
    Mgr->>Disp: resolve_tool_call(call, _latest_screen)
    Disp->>Disp: denormalize_box(0-999 -> PixelRect)
    Disp->>Disp: refine_with_ax_elements / refine_with_detected_rects
    Disp-->>Mgr: (DrawCommandMessage, FunctionResponse)
    Mgr-->>Mac: DrawCommandMessage(pixel_rect, matched_ax_role, matched_ax_title)
    Mgr->>Live: send_tool_response(function_responses)

    Live-->>Mgr: input_transcription / interim_input_transcription
    Mgr-->>Mac: InputTranscriptMessage(text, is_final)

    Live-->>Mgr: server_content.model_turn.parts (24 kHz PCM) & output_transcription
    Mgr-->>Mac: AudioDownMessage(pcm_b64)
    Mgr-->>Mac: HudStateMessage(state="listening", transcript_snippet=...)
```

---

## WebSocket Server & Wire Contract

### Connection Lifecycle ([`server.py`](src/sidecar/server.py))
- `run_server` binds `SIDECAR_HOST` (default `"0.0.0.0"`) and `SIDECAR_PORT` (default `8765`) using `websockets.serve(..., max_size=8 * 1024 * 1024)` (8 MiB frame limit to accommodate base64 JPEG screen frames).
- Each client connection in `handle_connection` instantiates a dedicated `GeminiLiveSessionManager(emit=emit)` instance.
- Incoming frames must be UTF-8 JSON text (`isinstance(raw_message, str)`). Payloads are parsed with `UPSTREAM_ADAPTER: TypeAdapter[UpstreamMessage]`.
  - Invalid payloads (`ValidationError`) are logged and skipped without terminating the socket.
  - Unexpected exceptions during `manager.handle_upstream(parsed)` emit `HudStateMessage(state="idle", transcript_snippet=f"Sidecar error: {exc}")`.
  - When the WebSocket closes, `finally: await manager.stop()` cancels the Live receive loop and closes the Gemini Live session context manager.

### Discriminated Unions ([`schemas.py`](src/sidecar/schemas.py))

All coordinates on the wire use **top-left origin pixel coordinates** (`PixelRect`, `Point2D`, `AXElementBounds`).

**`UpstreamMessage`** (discriminated on `"type"`):
1. `SessionControlMessage` (`"session_control"`): `action` in `{"start_session", "stop_session", "barge_in_manual"}`.
2. `ScreenContextMessage` (`"screen_context"`): `screen_width` (`> 0`), `screen_height` (`> 0`), `scale_factor` (default `1.0`, `> 0`), `jpeg_b64`, `ax_elements: list[AXElementBounds]`, `frontmost_bundle_id: str | None`, `detected_rects: list[DetectedRectBounds]`, and `document_context: DocumentContext | None`.
3. `AudioUpMessage` (`"audio_up"`): `pcm_b64` carrying 16 kHz, 16-bit, mono PCM microphone chunks.
4. `TextUpMessage` (`"text_up"`): `text` (`min_length=1`) for typed or dictated prompts.

**`DownstreamMessage`** (discriminated on `"type"`):
1. `DrawCommandMessage` (`"draw_command"`): `command_id`, `action` in `{"highlight_region", "point_arrow", "show_step_callout", "clear_annotations"}`, optional `pixel_rect`, `from_point`, `to_point`, `label`, `step_number`, `explanation`, `color` (default `"#3B82F6"`), `style`, `matched_ax_role`, and `matched_ax_title`.
2. `AudioDownMessage` (`"audio_down"`): `pcm_b64` carrying 24 kHz, 16-bit, mono PCM voice chunks from Gemini.
3. `BargeInMessage` (`"barge_in"`): `reason` in `{"vad_interrupted", "manual"}` (default `"vad_interrupted"`).
4. `HudStateMessage` (`"hud_state"`): `state` in `{"idle", "listening", "thinking", "drawing", "privacy_paused"}` and optional `transcript_snippet`.
5. `InputTranscriptMessage` (`"input_transcript"`): `text` and `is_final` (`bool`, default `False`) carrying live user speech transcriptions from Gemini Live.

---

## Gemini Live Session, Streaming & VAD Barge-In ([`live_session.py`](src/sidecar/live_session.py))

- **Client & Model Configuration:**
  - `GeminiLiveSessionManager` defaults to `os.environ.get("GEMINI_LIVE_MODEL", "gemini-3.8-live")` and lazily instantiates `genai.Client(http_options={"api_version": "v1beta"})`.
  - `build_live_config(session_resumption_handle=None)` configures `types.LiveConnectConfig` with:
    - `response_modalities=[types.Modality.AUDIO]`
    - `input_audio_transcription=types.AudioTranscriptionConfig()` and `output_audio_transcription=types.AudioTranscriptionConfig()`
    - `tools=get_overlay_tools()`
    - `context_window_compression=types.ContextWindowCompressionConfig(sliding_window=types.SlidingWindow())` to extend audio+video sessions past the ~2-minute uncompressed limit.
    - `session_resumption=types.SessionResumptionConfig(handle=session_resumption_handle)` to resume sessions across ~10-minute WebSocket connection resets using handles stored from `session_resumption_update` (and cleared on explicit `stop()`).
    - `system_instruction` instructing Parhlo to keep spoken explanations concise, wait for explicit user input, and invoke `highlight_region`, `point_arrow`, or `show_step_callout` with `0-999` `[ymin, xmin, ymax, xmax]` coordinates.
- **Concurrency & Lifecycle (`_session_lock`, `_receive_loop`):**
  - `self._session_lock` (`asyncio.Lock`) serializes `start()`, `stop()`, `_close_session_cm()`, upstream forwarding, and reconnect paths so concurrent `ScreenContextMessage`, `AudioUpMessage`, and `TextUpMessage` frames cannot race or leak sessions.
  - Because `google-genai`'s `AsyncSession.receive()` returns after each completed turn (`_is_interaction_complete`), `_receive_loop()` loops across consecutive `session.receive()` calls while `self._session is session and not self._stopping` so multi-turn voice/text sessions remain active.
- **Upstream Routing (`handle_upstream`):**
  - `SessionControlMessage`:
    - `start_session`: marks `_wants_active_session = True`, opens `client.aio.live.connect(...)`, launches `_receive_loop()`, and emits `HudStateMessage(state="listening")`.
    - `stop_session`: cancels `_reconnect_task` and `_receive_task`, clears `_session_resumption_handle`, closes `_session_cm`, and emits `HudStateMessage(state="idle")`.
    - `barge_in_manual`: resets `_has_active_drawings`, sets `_turn_idle_event`, emits `BargeInMessage(reason="manual")`, and sends `send_client_content(turn_complete=False)` when connected to interrupt active model generation.
  - `ScreenContextMessage`: always updates `self._latest_screen` and resets `_screen_sent_in_session = False`. When a Live session is open (or `_wants_active_session` is active), forwards `video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg")` via `send_realtime_input` without injecting periodic text turns.
  - `AudioUpMessage`: decodes `pcm_b64` and streams `audio=types.Blob(data=pcm_bytes, mime_type="audio/pcm;rate=16000")` via `send_realtime_input`. On session start or audio reconnect, restores the cached screen JPEG (`include_text_context=False`) without injecting `client_content` text into the audio stream.
  - `TextUpMessage`: lazily starts (or reconnects) the Live session, emits `HudStateMessage(state="thinking")`, forwards cached screen video if unsent, injects any changed `[UI Context]` (`summarize_ax_elements`) and `[Document Context]` (`summarize_document_context`) via `send_client_content(turns=types.Content(role="user", parts=...), turn_complete=False)`, and sends the user prompt with `turn_complete=True`.
- **VAD Barge-In, Resumption & Downstream Processing (`process_live_response`):**
  - **Session Resumption & `GoAway`:** Saves `session_resumption_update.new_handle` whenever `resumable` is true. On `go_away`, logs a warning and schedules `_proactive_reconnect(...)` (waiting briefly for any in-flight turn to finish via `_turn_idle_event`) to reconnect seamlessly with the stored handle when `_wants_active_session` is active.
  - **Tool Calls & Cancellations:** Resolves `response.tool_call.function_calls`, emits any resulting `DrawCommandMessage`, tracks `_has_active_drawings`, and returns `types.FunctionResponse` items via `send_tool_response(...)`. Logs `tool_call_cancellation.ids` cleanly when the server cancels pending calls.
  - **VAD Barge-In:** When `response.server_content.interrupted is True`, clears `_has_active_drawings`, sets `_turn_idle_event`, and emits `BargeInMessage(reason="vad_interrupted")`.
  - **Voice Audio, Transcripts & `interaction_status`:** Processes all `model_turn.parts` (`inline_data` 24 kHz PCM -> `AudioDownMessage`; non-thought `text` fallback), maps `input_transcription` and `interim_input_transcription` to `InputTranscriptMessage`, emits `output_transcription` as `HudStateMessage`, and keeps HUD in `"thinking"` (or `"drawing"`) across intermediate `turn_complete=True` events while `interaction_status == IN_PROGRESS` until `interaction_status == IDLE` (or standard `turn_complete` / `generation_complete`).

---

## `NON_BLOCKING` Tool Calling & Spatial Grounding Pipeline

### Tool Declarations ([`tools.py`](src/sidecar/tools.py))
`get_overlay_tools()` registers four `types.FunctionDeclaration` tools inside a single `types.Tool`, all configured with `behavior=types.Behavior.NON_BLOCKING` so Gemini does not stall voice synthesis while annotations are dispatched:

| Tool Name | Required Args | Optional Args | Target Coordinate Schema |
| :--- | :--- | :--- | :--- |
| `highlight_region` | `box_2d`, `label` | `style` (`box` / `spotlight`), `color` | `BOX_2D_SCHEMA`: `[ymin, xmin, ymax, xmax]` in `0–999` |
| `point_arrow` | `to_box_2d`, `label` | `from_box_2d`, `color` | `BOX_2D_SCHEMA` for `to_box_2d` and `from_box_2d` |
| `show_step_callout` | `box_2d`, `step_number`, `title`, `explanation` | — | `BOX_2D_SCHEMA` |
| `clear_annotations` | — | `reason` | None |

### Coordinate Denormalization & `AXUIElement` Snapping ([`tool_dispatcher.py`](src/sidecar/tool_dispatcher.py), [`grounding.py`](src/sidecar/grounding.py))

1. **Fallback Screen Dimensions:** `resolve_tool_call` reads `screen_width`, `screen_height`, and `ax_elements` from `self._latest_screen` (defaulting to `1512 x 982` and `[]` if no screen context has arrived yet) and assigns a UUIDv4 `command_id`.
2. **`0–999` Box Denormalization (`denormalize_box`):**
   - Validates a 4-element `[ymin, xmin, ymax, xmax]` sequence and positive `screen_width` / `screen_height`.
   - Clamps each coordinate to `[0, 999]` and swaps inverted bounds (`ymin > ymax`, `xmin > xmax`).
   - Scales to integer screen pixels (`int(coord / 1000 * dimension)`) and enforces `width >= 1`, `height >= 1` in `PixelRect`.
3. **Deterministic `AXUIElement` Snapping (`refine_with_ax_elements`):**
   - Evaluates every `AXElementBounds` with `width > 0` and `height > 0` from the latest `ScreenContextMessage`.
   - Computes:
     - `iou = compute_iou(rect, ax_rect)`
     - `label_sim = _label_similarity(target_label, ax)` (maximum `difflib.SequenceMatcher` ratio against `ax.title`, `ax.description`, and `ax.value`, case-insensitive)
     - `center_bonus = 0.15` when either box contains the other's center (`_contains_center`)
   - Composite score: `score = iou + (0.45 * label_sim) + center_bonus`.
   - Qualification gate (`iou_threshold = 0.35`): a candidate qualifies if `iou >= 0.35` **or** `(label_sim >= 0.75 and (iou > 0.05 or center_bonus > 0))`.
   - When a candidate qualifies, the highest-scoring `AXElementBounds` replaces the raw denormalized `PixelRect` and populates `matched_ax_role` and `matched_ax_title` on `DrawCommandMessage`; otherwise, the raw denormalized `PixelRect` is preserved with `matched_ax_role=None`.
4. **Action-Specific Resolution:**
   - `highlight_region`: snaps `box_2d` using `label` (defaults `style="box"`, `color="#3B82F6"`).
   - `point_arrow`: snaps `to_box_2d` using `label` and sets `to_point = rect_center(to_snapped)`; if `from_box_2d` is present, denormalizes it without snapping and sets `from_point = rect_center(from_raw)` (defaults `color="#10B981"`).
   - `show_step_callout`: snaps `box_2d` using `title` and maps `title` to `DrawCommandMessage.label` alongside `step_number` and `explanation`.
   - `clear_annotations`: emits `action="clear_annotations"` with `explanation=args.get("reason")`.
   - All tools return `types.FunctionResponse(id=call.id, name=name, response={"status": "rendered", "command_id": cmd_id})`.

---

## Container Runtime (`Dockerfile`, `compose.yaml`, `pyproject.toml`)

- **Base Image & Virtualenv ([`../Dockerfile`](../Dockerfile)):**
  - `base` stage pins `python:3.12-slim`, sets `PYTHONDONTWRITEBYTECODE=1` and `PYTHONUNBUFFERED=1`, and creates an isolated virtualenv at `VENV_PATH=/opt/venv`.
  - `dev` stage installs editable package + dev extras (`pip install --no-cache-dir -e "/app/agent-sidecar[dev]"`) including `pytest>=8.3.0`, `pytest-asyncio>=0.24.0`, and `watchfiles>=1.0.0`, copies `tests/`, and defaults to `watchfiles --filter python "python -m sidecar.server" /app/agent-sidecar/src`.
  - `prod` stage installs only runtime dependencies (`google-genai>=3.2.0`, `pydantic>=2.9.0`, `websockets>=13.0`) without `tests/` or `dev` extras and launches `python -m sidecar.server`.
- **Compose Service & Live Reloading ([`../compose.yaml`](../compose.yaml)):**
  - Service `sidecar` builds `target: dev`, publishes `"127.0.0.1:8765:8765"`, loads optional `.env` (`required: false`, documented in [`.env.example`](../.env.example)), sets `SIDECAR_HOST=0.0.0.0` and `SIDECAR_PORT=8765`, bind-mounts `./agent-sidecar:/app/agent-sidecar`, isolates `/opt/venv` in the named volume `sidecar_venv`, and runs `watchfiles --filter python "python -m sidecar.server" /app/agent-sidecar/src` so host Python edits reload automatically inside the container without rebuilding.
  - Standard container workflows: `docker compose up --build` to run the auto-reloading WebSocket sidecar and `docker compose run --rm sidecar pytest -v` to execute the test suite inside Docker. (If upgrading an existing `sidecar_venv` volume created before `watchfiles` was added, refresh it once with `docker compose down -v && docker compose up --build`.)
