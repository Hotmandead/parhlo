"""Gemini Live API session manager for bidirectional voice, screen context, and tool calls."""

import asyncio
import base64
from collections.abc import Awaitable, Callable
import logging
import os

from google import genai
from google.genai import types

from sidecar.schemas import (
    AudioDownMessage,
    AudioUpMessage,
    BargeInMessage,
    DownstreamMessage,
    HudStateMessage,
    InputTranscriptMessage,
    ScreenContextMessage,
    SessionControlMessage,
    TextUpMessage,
    UpstreamMessage,
)
from sidecar.tool_dispatcher import resolve_tool_call
from sidecar.tools import get_overlay_tools

logger = logging.getLogger(__name__)

EmitCallback = Callable[[DownstreamMessage], Awaitable[None]]


def build_live_config(
    session_resumption_handle: str | None = None,
) -> types.LiveConnectConfig:
    """Build the Gemini Live API connection configuration for Parhlo."""
    return types.LiveConnectConfig(
        response_modalities=[types.Modality.AUDIO],
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        tools=get_overlay_tools(),
        context_window_compression=types.ContextWindowCompressionConfig(
            sliding_window=types.SlidingWindow(),
        ),
        session_resumption=types.SessionResumptionConfig(
            handle=session_resumption_handle,
        ),
        system_instruction=types.Content(
            parts=[
                types.Part(
                    text=(
                        "You are Parhlo, a real-time macOS screen assistant. "
                        "Keep spoken explanations concise and natural. "
                        "Wait for the user's explicit spoken or typed request before responding, "
                        "and do not initiate unprompted follow-up questions or commentary on screen changes. "
                        "Whenever referencing UI controls on screen, call highlight_region, "
                        "point_arrow, or show_step_callout with 0-999 [ymin, xmin, ymax, xmax] coordinates."
                    )
                )
            ]
        ),
    )


def _parse_duration_seconds(duration: object) -> float | None:
    if duration is None:
        return None
    if isinstance(duration, (int, float)) and not isinstance(duration, bool):
        return max(0.0, float(duration))
    if isinstance(duration, str):
        raw = duration.strip().lower()
        try:
            if raw.endswith("ms"):
                return max(0.0, float(raw[:-2]) / 1000.0)
            if raw.endswith("s"):
                return max(0.0, float(raw[:-1]))
            return max(0.0, float(raw))
        except ValueError:
            return None
    return None


def _normalize_interaction_status(status: object) -> str | None:
    if status is None:
        return None
    if isinstance(status, types.InteractionStatus):
        value = status.value
    elif hasattr(status, "value") and isinstance(status.value, str):
        value = status.value
    elif isinstance(status, str):
        value = status
    else:
        return None
    normalized = value.strip().upper()
    if "." in normalized:
        normalized = normalized.rsplit(".", 1)[-1]
    if not normalized or normalized == "INTERACTION_STATUS_UNSPECIFIED":
        return None
    return normalized


def _is_interaction_complete(content: object) -> bool:
    if not content:
        return False
    status = _normalize_interaction_status(getattr(content, "interaction_status", None))
    if status is not None:
        return status == "IDLE"
    return getattr(content, "turn_complete", False) is True


def summarize_ax_elements(ctx: ScreenContextMessage, limit: int = 30) -> str:
    """Create a compact text summary of visible AXUIElements for Gemini context."""
    detected_rects = getattr(ctx, "detected_rects", None) or []
    if not ctx.ax_elements and not detected_rects:
        return ""
    lines = [f"Frontmost app: {ctx.frontmost_bundle_id or 'unknown'} ({ctx.screen_width}x{ctx.screen_height})"]
    if ctx.ax_elements:
        for ax in ctx.ax_elements[:limit]:
            label = ax.title or ax.description or ax.value or ""
            lines.append(f"- {ax.role}: {label!r} @ ({ax.x},{ax.y},{ax.width}x{ax.height})")
    else:
        lines.append(f"Vision-detected UI rectangles ({len(detected_rects)} total):")
        for rect in detected_rects[:10]:
            lines.append(f"- vision_rect @ ({rect.x},{rect.y},{rect.width}x{rect.height})")
    return "\n".join(lines)


def summarize_document_context(ctx: ScreenContextMessage) -> str:
    """Create a compact text summary of on-screen document structure for Gemini context."""
    doc = getattr(ctx, "document_context", None)
    if doc is None:
        return ""
    lines: list[str] = []
    if doc.title:
        lines.append(f"Document title: {doc.title}")
    for para in doc.paragraphs:
        if para:
            lines.append(f"- {para}")
    for idx, table in enumerate(doc.tables, start=1):
        if table.rows:
            row_strs = [" | ".join(row) for row in table.rows if row]
            if row_strs:
                lines.append(f"Table {idx}: " + "; ".join(row_strs))
    return "\n".join(lines)


class GeminiLiveSessionManager:
    """Manages a single client's Gemini Live API session and spatial tool resolution."""

    def __init__(
        self,
        emit: EmitCallback,
        model: str | None = None,
        client: genai.Client | None = None,
    ) -> None:
        self._emit = emit
        self._model = model or os.environ.get("GEMINI_LIVE_MODEL", "gemini-3.8-live")
        self._client = client
        self._session_cm = None
        self._session = None
        self._receive_task: asyncio.Task[None] | None = None
        self._reconnect_task: asyncio.Task[None] | None = None
        self._session_lock = asyncio.Lock()
        self._turn_idle_event = asyncio.Event()
        self._turn_idle_event.set()
        self._latest_screen: ScreenContextMessage | None = None
        self._last_ax_summary: str = ""
        self._last_doc_summary: str = ""
        self._screen_sent_in_session: bool = False
        self._session_resumption_handle: str | None = None
        self._go_away_received: bool = False
        self._wants_active_session: bool = False
        self._has_active_drawings: bool = False
        self._stopping: bool = False

    def _get_client(self) -> genai.Client:
        if self._client is None:
            self._client = genai.Client(http_options={"api_version": "v1beta"})
        return self._client

    async def start(self) -> None:
        """Open the Gemini Live API session and start receiving server events."""
        async with self._session_lock:
            await self._start_locked()

    async def _start_locked(self) -> None:
        if self._session is not None:
            return
        self._stopping = False
        self._go_away_received = False
        self._turn_idle_event.set()
        self._last_ax_summary = ""
        self._last_doc_summary = ""
        self._screen_sent_in_session = False
        client = self._get_client()
        handle = self._session_resumption_handle
        session_cm = client.aio.live.connect(
            model=self._model,
            config=build_live_config(session_resumption_handle=handle),
        )
        try:
            session = await session_cm.__aenter__()
        except Exception as exc:
            if handle is None:
                raise
            logger.warning(
                "Failed to resume Gemini Live session with handle (%s); starting fresh session",
                exc,
            )
            self._session_resumption_handle = None
            session_cm = client.aio.live.connect(
                model=self._model,
                config=build_live_config(session_resumption_handle=None),
            )
            session = await session_cm.__aenter__()

        self._session_cm = session_cm
        self._session = session
        self._receive_task = asyncio.create_task(self._receive_loop())
        await self._emit(HudStateMessage(state="listening"))

    async def stop(self) -> None:
        """Close the Gemini Live API session and cancel background tasks."""
        async with self._session_lock:
            self._stopping = True
            self._wants_active_session = False
            self._has_active_drawings = False
            self._session_resumption_handle = None
            self._go_away_received = False
            self._turn_idle_event.set()
            try:
                reconnect_task = self._reconnect_task
                self._reconnect_task = None
                if reconnect_task is not None and reconnect_task is not asyncio.current_task():
                    reconnect_task.cancel()
                    try:
                        await reconnect_task
                    except asyncio.CancelledError:
                        pass

                await self._close_session_cm_locked()
                await self._emit(HudStateMessage(state="idle"))
            finally:
                self._stopping = False

    async def _close_session_cm(self) -> None:
        async with self._session_lock:
            await self._close_session_cm_locked(cancel_reconnect=True)

    async def _close_session_cm_locked(self, *, cancel_reconnect: bool = False) -> None:
        session_cm = self._session_cm
        receive_task = self._receive_task
        self._session_cm = None
        self._session = None
        self._receive_task = None
        self._go_away_received = False
        self._turn_idle_event.set()
        self._last_ax_summary = ""
        self._last_doc_summary = ""
        self._screen_sent_in_session = False
        if cancel_reconnect:
            reconnect_task = self._reconnect_task
            self._reconnect_task = None
            if reconnect_task is not None and reconnect_task is not asyncio.current_task():
                reconnect_task.cancel()
                try:
                    await reconnect_task
                except asyncio.CancelledError:
                    pass
        if receive_task is not None and receive_task is not asyncio.current_task():
            receive_task.cancel()
            try:
                await receive_task
            except asyncio.CancelledError:
                pass
        if session_cm is not None:
            try:
                await session_cm.__aexit__(None, None, None)
            except Exception:
                logger.debug("Ignoring error while closing stale Live session", exc_info=True)

    async def _forward_screen_context_raw(
        self,
        message: ScreenContextMessage,
        *,
        include_text_context: bool = False,
    ) -> None:
        """Send screen image and optionally changed UI/Document context."""
        session = self._session
        if session is None:
            return
        jpeg_bytes = base64.b64decode(message.jpeg_b64)
        await session.send_realtime_input(
            video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg"),
        )
        if include_text_context:
            await self._send_changed_text_context(message)
        if self._session is session:
            self._screen_sent_in_session = True

    async def _send_changed_text_context(self, message: ScreenContextMessage) -> None:
        """Send changed UI/Document context as non-completing client content."""
        session = self._session
        if session is None:
            return
        parts: list[types.Part] = []
        summary = summarize_ax_elements(message)
        pending_ax = summary if (summary and summary != self._last_ax_summary) else None
        if pending_ax:
            parts.append(types.Part(text=f"[UI Context]\n{pending_ax}"))
        doc_summary = summarize_document_context(message)
        pending_doc = doc_summary if (doc_summary and doc_summary != self._last_doc_summary) else None
        if pending_doc:
            parts.append(types.Part(text=f"[Document Context]\n{pending_doc}"))
        if not parts or self._session is not session:
            return
        await session.send_client_content(
            turns=types.Content(role="user", parts=parts),
            turn_complete=False,
        )
        if pending_ax:
            self._last_ax_summary = pending_ax
        if pending_doc:
            self._last_doc_summary = pending_doc

    async def _forward_screen_context_locked(
        self,
        message: ScreenContextMessage,
        *,
        allow_restart: bool = False,
        include_text_context: bool = False,
    ) -> None:
        was_open = self._session is not None
        if not was_open:
            if not allow_restart:
                return
            await self._start_locked()
        if self._session is None:
            return
        try:
            await self._forward_screen_context_raw(
                message,
                include_text_context=include_text_context,
            )
        except Exception as exc:
            if not allow_restart or not was_open:
                logger.debug("Live screen context send failed (%s); resetting stale session", exc)
                await self._close_session_cm_locked(cancel_reconnect=True)
                return
            logger.warning("Live screen context send failed (%s); reconnecting and retrying", exc)
            await self._close_session_cm_locked(cancel_reconnect=True)
            await self._start_locked()
            if self._session is not None:
                try:
                    await self._forward_screen_context_raw(
                        message,
                        include_text_context=include_text_context,
                    )
                except Exception as retry_exc:
                    logger.warning("Live screen context retry failed (%s); resetting session", retry_exc)
                    await self._close_session_cm_locked(cancel_reconnect=True)

    async def _send_audio_with_reconnect_locked(
        self,
        audio_blob: types.Blob,
        *,
        allow_restart: bool,
    ) -> None:
        was_open = self._session is not None
        if not was_open:
            if not allow_restart:
                return
            await self._start_locked()
            if self._session is not None and self._latest_screen is not None and not self._screen_sent_in_session:
                await self._forward_screen_context_raw(
                    self._latest_screen,
                    include_text_context=False,
                )
        if self._session is None:
            return
        try:
            await self._session.send_realtime_input(audio=audio_blob)
        except Exception as exc:
            if not allow_restart or not was_open:
                logger.debug("Live audio send failed (%s); resetting stale session", exc)
                await self._close_session_cm_locked(cancel_reconnect=True)
                return
            logger.warning("Live audio send failed (%s); reconnecting and retrying", exc)
            await self._close_session_cm_locked(cancel_reconnect=True)
            await self._start_locked()
            if self._session is not None:
                try:
                    if self._latest_screen is not None and not self._screen_sent_in_session:
                        await self._forward_screen_context_raw(
                            self._latest_screen,
                            include_text_context=False,
                        )
                    await self._session.send_realtime_input(audio=audio_blob)
                except Exception as retry_exc:
                    logger.warning("Live audio retry failed (%s); resetting session", retry_exc)
                    await self._close_session_cm_locked(cancel_reconnect=True)

    async def _send_text_turn_once_locked(self, text: str) -> None:
        if self._session is None:
            await self._start_locked()
        if self._latest_screen is not None:
            if not self._screen_sent_in_session:
                await self._forward_screen_context_raw(
                    self._latest_screen,
                    include_text_context=True,
                )
            else:
                await self._send_changed_text_context(self._latest_screen)
        if self._session is None:
            raise RuntimeError("Live session unavailable after start")
        self._turn_idle_event.clear()
        await self._session.send_client_content(
            turns=types.Content(role="user", parts=[types.Part(text=text)]),
            turn_complete=True,
        )

    async def _proactive_reconnect(self, expected_session, wait_seconds: float) -> None:
        try:
            if wait_seconds > 0 and not self._turn_idle_event.is_set():
                try:
                    await asyncio.wait_for(self._turn_idle_event.wait(), timeout=wait_seconds)
                except asyncio.TimeoutError:
                    pass
            async with self._session_lock:
                if self._stopping or not self._wants_active_session:
                    return
                if self._session is not None and self._session is not expected_session:
                    return
                logger.info(
                    "Proactively reconnecting Gemini Live session after GoAway (resuming=%s)",
                    bool(self._session_resumption_handle),
                )
                await self._close_session_cm_locked(cancel_reconnect=False)
                await self._start_locked()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Proactive GoAway reconnect failed")
            if not self._stopping:
                self._has_active_drawings = False
                await self._emit(
                    HudStateMessage(state="idle", transcript_snippet="Live session disconnected")
                )
        finally:
            if self._reconnect_task is asyncio.current_task():
                self._reconnect_task = None

    async def handle_upstream(self, message: UpstreamMessage) -> None:
        """Route an incoming macos-app message to the active Live session."""
        if isinstance(message, SessionControlMessage):
            if message.action == "start_session":
                async with self._session_lock:
                    self._wants_active_session = True
                    await self._start_locked()
            elif message.action == "stop_session":
                await self.stop()
            elif message.action == "barge_in_manual":
                self._has_active_drawings = False
                self._turn_idle_event.set()
                await self._emit(BargeInMessage(reason="manual"))
                async with self._session_lock:
                    session = self._session
                    if session is not None:
                        try:
                            await session.send_client_content(turn_complete=False)
                        except Exception as exc:
                            logger.debug("Ignoring error sending manual barge-in signal (%s)", exc)
            return

        if isinstance(message, ScreenContextMessage):
            async with self._session_lock:
                self._latest_screen = message
                self._screen_sent_in_session = False
                if self._session is not None or self._wants_active_session:
                    await self._forward_screen_context_locked(
                        message, allow_restart=self._wants_active_session
                    )
            return

        if isinstance(message, AudioUpMessage):
            if self._session is None and not self._wants_active_session:
                return
            pcm_bytes = base64.b64decode(message.pcm_b64)
            async with self._session_lock:
                if self._session is None and not self._wants_active_session:
                    return
                await self._send_audio_with_reconnect_locked(
                    types.Blob(data=pcm_bytes, mime_type="audio/pcm;rate=16000"),
                    allow_restart=self._wants_active_session,
                )
            return

        if isinstance(message, TextUpMessage):
            await self._emit(HudStateMessage(state="thinking"))
            async with self._session_lock:
                had_existing_session = self._session is not None
                try:
                    await self._send_text_turn_once_locked(message.text)
                except Exception as exc:
                    if not had_existing_session:
                        await self._close_session_cm_locked(cancel_reconnect=True)
                        raise
                    logger.warning("Live session text turn failed (%s); reconnecting and retrying", exc)
                    await self._close_session_cm_locked(cancel_reconnect=True)
                    await self._start_locked()
                    try:
                        await self._send_text_turn_once_locked(message.text)
                    except Exception:
                        await self._close_session_cm_locked(cancel_reconnect=True)
                        raise

    async def _receive_loop(self) -> None:
        session = self._session
        assert session is not None
        errored = False
        cancelled = False
        try:
            while self._session is session and not self._stopping:
                received_any = False
                turn_ended = False
                async for response in session.receive():
                    received_any = True
                    if self._session is not session or self._stopping:
                        break
                    await self.process_live_response(response)
                    if _is_interaction_complete(getattr(response, "server_content", None)):
                        turn_ended = True
                if not received_any or not turn_ended:
                    break
        except asyncio.CancelledError:
            cancelled = True
            raise
        except Exception:
            errored = True
            reconnecting = self._reconnect_task is not None and not self._reconnect_task.done()
            if reconnecting:
                logger.info("Gemini Live receive loop ended while proactive reconnect is pending")
            else:
                logger.exception("Error in Gemini Live receive loop")
                if not self._stopping:
                    self._has_active_drawings = False
                    await self._emit(
                        HudStateMessage(state="idle", transcript_snippet="Live session disconnected")
                    )
        finally:
            closed_current = False
            if self._session is session and not self._stopping:
                async with self._session_lock:
                    if self._session is session and not self._stopping:
                        await self._close_session_cm_locked()
                        closed_current = True
                    if self._receive_task is asyncio.current_task():
                        self._receive_task = None
            elif self._receive_task is asyncio.current_task():
                self._receive_task = None
            reconnecting = self._reconnect_task is not None and not self._reconnect_task.done()
            if closed_current and not cancelled and not errored and not self._stopping and not reconnecting:
                self._has_active_drawings = False
                await self._emit(HudStateMessage(state="idle"))

    async def process_live_response(self, response) -> None:
        """Process resumption updates, tool calls, GoAway, and server content from a Live event."""
        resumption_update = getattr(response, "session_resumption_update", None)
        if resumption_update is not None:
            new_handle = getattr(resumption_update, "new_handle", None)
            if getattr(resumption_update, "resumable", False) and new_handle:
                self._session_resumption_handle = new_handle

        tool_call = getattr(response, "tool_call", None)
        if tool_call and getattr(tool_call, "function_calls", None):
            await self._handle_tool_calls(tool_call.function_calls)

        tool_cancellation = getattr(response, "tool_call_cancellation", None)
        if tool_cancellation and getattr(tool_cancellation, "ids", None):
            logger.info("Gemini Live cancelled tool calls: %s", tool_cancellation.ids)

        go_away = getattr(response, "go_away", None)
        if go_away is not None:
            time_left = getattr(go_away, "time_left", None)
            logger.warning("Received Gemini Live GoAway signal (time_left=%s)", time_left)
            self._go_away_received = True
            if (
                self._wants_active_session
                and not self._stopping
                and self._session is not None
                and self._reconnect_task is None
            ):
                parsed_seconds = _parse_duration_seconds(time_left)
                wait_seconds = (
                    0.0
                    if parsed_seconds is None
                    else max(0.0, min(5.0, parsed_seconds - 2.0))
                )
                self._reconnect_task = asyncio.create_task(
                    self._proactive_reconnect(self._session, wait_seconds)
                )

        content = getattr(response, "server_content", None)
        if not content:
            return

        if getattr(content, "interrupted", False) is True:
            self._has_active_drawings = False
            self._turn_idle_event.set()
            await self._emit(BargeInMessage(reason="vad_interrupted"))

        model_turn = getattr(content, "model_turn", None)
        model_parts = getattr(model_turn, "parts", None) if model_turn else None
        has_model_parts = bool(model_parts)
        if model_parts:
            self._turn_idle_event.clear()
            for part in model_parts:
                inline_data = getattr(part, "inline_data", None)
                if inline_data and getattr(inline_data, "data", None):
                    raw = inline_data.data
                    if isinstance(raw, str):
                        pcm_b64 = raw
                    else:
                        pcm_b64 = base64.b64encode(bytes(raw)).decode("ascii")
                    await self._emit(AudioDownMessage(pcm_b64=pcm_b64))

        in_tx = getattr(content, "input_transcription", None)
        interim_tx = getattr(content, "interim_input_transcription", None)
        if in_tx and getattr(in_tx, "text", None):
            logger.debug("Input transcription: %s", in_tx.text)
            await self._emit(
                InputTranscriptMessage(
                    text=in_tx.text,
                    is_final=bool(getattr(in_tx, "finished", False)),
                )
            )
        elif interim_tx and getattr(interim_tx, "text", None):
            logger.debug("Interim input transcription: %s", interim_tx.text)
            await self._emit(
                InputTranscriptMessage(
                    text=interim_tx.text,
                    is_final=False,
                )
            )

        out_tx = getattr(content, "output_transcription", None)
        has_output_tx = bool(out_tx and getattr(out_tx, "text", None))
        if has_output_tx:
            self._turn_idle_event.clear()
            hud_state = "drawing" if self._has_active_drawings else "listening"
            await self._emit(HudStateMessage(state=hud_state, transcript_snippet=out_tx.text))
        elif model_parts:
            text_chunks = [
                part.text
                for part in model_parts
                if getattr(part, "text", None) and not getattr(part, "thought", False)
            ]
            if text_chunks:
                self._turn_idle_event.clear()
                hud_state = "drawing" if self._has_active_drawings else "listening"
                await self._emit(
                    HudStateMessage(state=hud_state, transcript_snippet="".join(text_chunks))
                )

        turn_complete = getattr(content, "turn_complete", False) is True
        generation_complete = getattr(content, "generation_complete", False) is True
        interaction_status = _normalize_interaction_status(
            getattr(content, "interaction_status", None)
        )

        if interaction_status == "IN_PROGRESS":
            self._turn_idle_event.clear()
            if turn_complete or generation_complete or (not has_output_tx and not has_model_parts):
                hud_state = "drawing" if self._has_active_drawings else "thinking"
                await self._emit(HudStateMessage(state=hud_state))
        elif interaction_status == "IDLE" or turn_complete or generation_complete:
            self._turn_idle_event.set()
            hud_state = "drawing" if self._has_active_drawings else "idle"
            await self._emit(HudStateMessage(state=hud_state))

    async def _handle_tool_calls(self, function_calls) -> None:
        session = self._session
        responses: list[types.FunctionResponse] = []
        for call in function_calls:
            command, response = resolve_tool_call(call, self._latest_screen)
            if command is not None:
                if command.action == "clear_annotations":
                    self._has_active_drawings = False
                else:
                    self._has_active_drawings = True
                await self._emit(command)
            responses.append(response)

        if session is not None and responses:
            try:
                await session.send_tool_response(function_responses=responses)
            except Exception as exc:
                logger.warning("Failed to send tool response (%s); closing stale session", exc)
                async with self._session_lock:
                    if self._session is session:
                        await self._close_session_cm_locked(cancel_reconnect=True)
