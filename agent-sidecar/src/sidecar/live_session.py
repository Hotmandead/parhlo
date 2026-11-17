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


def build_live_config() -> types.LiveConnectConfig:
    """Build the Gemini Live API connection configuration for Parhlo."""
    return types.LiveConnectConfig(
        response_modalities=[types.Modality.AUDIO],
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        tools=get_overlay_tools(),
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
        self._latest_screen: ScreenContextMessage | None = None
        self._last_ax_summary: str = ""
        self._last_doc_summary: str = ""
        self._screen_sent_in_session: bool = False
        self._wants_active_session: bool = False
        self._has_active_drawings: bool = False
        self._stopping: bool = False

    def _get_client(self) -> genai.Client:
        if self._client is None:
            self._client = genai.Client(http_options={"api_version": "v1beta"})
        return self._client

    async def start(self) -> None:
        """Open the Gemini Live API session and start receiving server events."""
        if self._session is not None:
            return
        self._stopping = False
        self._last_ax_summary = ""
        self._last_doc_summary = ""
        self._screen_sent_in_session = False
        client = self._get_client()
        self._session_cm = client.aio.live.connect(model=self._model, config=build_live_config())
        self._session = await self._session_cm.__aenter__()
        self._receive_task = asyncio.create_task(self._receive_loop())
        await self._emit(HudStateMessage(state="listening"))

    async def stop(self) -> None:
        """Close the Gemini Live API session and cancel background tasks."""
        self._stopping = True
        self._wants_active_session = False
        self._has_active_drawings = False
        try:
            receive_task = self._receive_task
            self._receive_task = None
            if receive_task is not None and receive_task is not asyncio.current_task():
                receive_task.cancel()
                try:
                    await receive_task
                except asyncio.CancelledError:
                    pass

            await self._close_session_cm()
            await self._emit(HudStateMessage(state="idle"))
        finally:
            self._stopping = False

    async def _close_session_cm(self) -> None:
        session_cm = self._session_cm
        self._session_cm = None
        self._session = None
        self._last_ax_summary = ""
        self._last_doc_summary = ""
        self._screen_sent_in_session = False
        if session_cm is not None:
            try:
                await session_cm.__aexit__(None, None, None)
            except Exception:
                logger.debug("Ignoring error while closing stale Live session", exc_info=True)

    async def _forward_screen_context_raw(
        self,
        message: ScreenContextMessage,
        *,
        include_text_context: bool = True,
    ) -> None:
        """Send screen image and (when starting a turn) changed UI/Document context."""
        if self._session is None:
            return
        jpeg_bytes = base64.b64decode(message.jpeg_b64)
        await self._session.send_realtime_input(
            video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg"),
        )
        if include_text_context:
            await self._send_changed_text_context(message)
        if self._session is not None:
            self._screen_sent_in_session = True

    async def _send_changed_text_context(self, message: ScreenContextMessage) -> None:
        """Send changed UI/Document context along with an explicit user turn."""
        if self._session is None:
            return
        summary = summarize_ax_elements(message)
        if summary and summary != self._last_ax_summary and self._session is not None:
            await self._session.send_realtime_input(text=f"[UI Context]\n{summary}")
            self._last_ax_summary = summary
        doc_summary = summarize_document_context(message)
        if doc_summary and doc_summary != self._last_doc_summary and self._session is not None:
            await self._session.send_realtime_input(text=f"[Document Context]\n{doc_summary}")
            self._last_doc_summary = doc_summary

    async def _forward_screen_context(
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
            await self.start()
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
                await self._close_session_cm()
                return
            logger.warning("Live screen context send failed (%s); reconnecting and retrying", exc)
            await self._close_session_cm()
            await self.start()
            if self._session is not None:
                try:
                    await self._forward_screen_context_raw(
                        message,
                        include_text_context=include_text_context,
                    )
                except Exception as retry_exc:
                    logger.warning("Live screen context retry failed (%s); resetting session", retry_exc)
                    await self._close_session_cm()

    async def _send_audio_with_reconnect(
        self,
        audio_blob: types.Blob,
        *,
        allow_restart: bool,
    ) -> None:
        was_open = self._session is not None
        if not was_open:
            if not allow_restart:
                return
            await self.start()
            if self._session is not None and self._latest_screen is not None and not self._screen_sent_in_session:
                await self._forward_screen_context_raw(self._latest_screen)
        if self._session is None:
            return
        try:
            await self._session.send_realtime_input(audio=audio_blob)
        except Exception as exc:
            if not allow_restart or not was_open:
                logger.debug("Live audio send failed (%s); resetting stale session", exc)
                await self._close_session_cm()
                return
            logger.warning("Live audio send failed (%s); reconnecting and retrying", exc)
            await self._close_session_cm()
            await self.start()
            if self._session is not None:
                try:
                    if self._latest_screen is not None and not self._screen_sent_in_session:
                        await self._forward_screen_context_raw(self._latest_screen)
                    await self._session.send_realtime_input(audio=audio_blob)
                except Exception as retry_exc:
                    logger.warning("Live audio retry failed (%s); resetting session", retry_exc)
                    await self._close_session_cm()

    async def _send_text_turn_once(self, text: str) -> None:
        if self._session is None:
            await self.start()
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
        await self._session.send_client_content(
            turns=types.Content(role="user", parts=[types.Part(text=text)]),
            turn_complete=True,
        )

    async def handle_upstream(self, message: UpstreamMessage) -> None:
        """Route an incoming macos-app message to the active Live session."""
        if isinstance(message, SessionControlMessage):
            if message.action == "start_session":
                self._wants_active_session = True
                await self.start()
            elif message.action == "stop_session":
                await self.stop()
            elif message.action == "barge_in_manual":
                self._has_active_drawings = False
                await self._emit(BargeInMessage(reason="manual"))
                if self._session is not None:
                    try:
                        await self._session.send_client_content(turn_complete=False)
                    except Exception as exc:
                        logger.debug("Ignoring error sending manual barge-in signal (%s)", exc)
            return

        if isinstance(message, ScreenContextMessage):
            self._latest_screen = message
            self._screen_sent_in_session = False
            if self._session is not None or self._wants_active_session:
                await self._forward_screen_context(
                    message, allow_restart=self._wants_active_session
                )
            return

        if isinstance(message, AudioUpMessage):
            if self._session is None and not self._wants_active_session:
                return
            pcm_bytes = base64.b64decode(message.pcm_b64)
            await self._send_audio_with_reconnect(
                types.Blob(data=pcm_bytes, mime_type="audio/pcm;rate=16000"),
                allow_restart=self._wants_active_session,
            )
            return

        if isinstance(message, TextUpMessage):
            await self._emit(HudStateMessage(state="thinking"))
            had_existing_session = self._session is not None
            try:
                await self._send_text_turn_once(message.text)
            except Exception as exc:
                if not had_existing_session:
                    await self._close_session_cm()
                    raise
                logger.warning("Live session text turn failed (%s); reconnecting and retrying", exc)
                await self._close_session_cm()
                await self.start()
                await self._send_text_turn_once(message.text)

    async def _receive_loop(self) -> None:
        session = self._session
        assert session is not None
        errored = False
        cancelled = False
        try:
            async for response in session.receive():
                await self.process_live_response(response)
        except asyncio.CancelledError:
            cancelled = True
            raise
        except Exception:
            errored = True
            logger.exception("Error in Gemini Live receive loop")
            if not self._stopping:
                self._has_active_drawings = False
                await self._emit(
                    HudStateMessage(state="idle", transcript_snippet="Live session disconnected")
                )
        finally:
            if self._session is session:
                await self._close_session_cm()
            if self._receive_task is asyncio.current_task():
                self._receive_task = None
            if not cancelled and not errored and not self._stopping:
                self._has_active_drawings = False
                await self._emit(HudStateMessage(state="idle"))

    async def process_live_response(self, response) -> None:
        """Process tool calls and server content from a Gemini Live API event."""
        if getattr(response, "tool_call", None) and response.tool_call.function_calls:
            await self._handle_tool_calls(response.tool_call.function_calls)

        go_away = getattr(response, "go_away", None)
        if go_away is not None:
            logger.warning(
                "Received Gemini Live GoAway signal (time_left=%s)",
                getattr(go_away, "time_left", None),
            )

        content = getattr(response, "server_content", None)
        if not content:
            return

        if getattr(content, "interrupted", False) is True:
            self._has_active_drawings = False
            await self._emit(BargeInMessage(reason="vad_interrupted"))

        model_turn = getattr(content, "model_turn", None)
        if model_turn and getattr(model_turn, "parts", None):
            for part in model_turn.parts:
                inline_data = getattr(part, "inline_data", None)
                if inline_data and getattr(inline_data, "data", None):
                    raw = inline_data.data
                    if isinstance(raw, str):
                        pcm_b64 = raw
                    else:
                        pcm_b64 = base64.b64encode(raw).decode("ascii")
                    await self._emit(AudioDownMessage(pcm_b64=pcm_b64))

        in_tx = getattr(content, "input_transcription", None)
        if in_tx and getattr(in_tx, "text", None):
            logger.debug("Input transcription: %s", in_tx.text)
            await self._emit(
                InputTranscriptMessage(
                    text=in_tx.text,
                    is_final=bool(getattr(in_tx, "finished", False)),
                )
            )

        out_tx = getattr(content, "output_transcription", None)
        if out_tx and getattr(out_tx, "text", None):
            hud_state = "drawing" if self._has_active_drawings else "listening"
            await self._emit(HudStateMessage(state=hud_state, transcript_snippet=out_tx.text))

        turn_complete = getattr(content, "turn_complete", False) is True
        generation_complete = getattr(content, "generation_complete", False) is True
        if turn_complete or generation_complete:
            hud_state = "drawing" if self._has_active_drawings else "idle"
            await self._emit(HudStateMessage(state=hud_state))

    async def _handle_tool_calls(self, function_calls) -> None:
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

        if self._session is not None and responses:
            try:
                await self._session.send_tool_response(function_responses=responses)
            except Exception as exc:
                logger.warning("Failed to send tool response (%s); closing stale session", exc)
                await self._close_session_cm()
