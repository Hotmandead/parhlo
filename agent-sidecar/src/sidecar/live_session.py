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
                        "Whenever referencing UI controls on screen, call highlight_region, "
                        "point_arrow, or show_step_callout with 0-999 [ymin, xmin, ymax, xmax] coordinates."
                    )
                )
            ]
        ),
    )


def summarize_ax_elements(ctx: ScreenContextMessage, limit: int = 30) -> str:
    """Create a compact text summary of visible AXUIElements for Gemini context."""
    if not ctx.ax_elements:
        return ""
    lines = [f"Frontmost app: {ctx.frontmost_bundle_id or 'unknown'} ({ctx.screen_width}x{ctx.screen_height})"]
    for ax in ctx.ax_elements[:limit]:
        label = ax.title or ax.description or ax.value or ""
        lines.append(f"- {ax.role}: {label!r} @ ({ax.x},{ax.y},{ax.width}x{ax.height})")
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

    def _get_client(self) -> genai.Client:
        if self._client is None:
            self._client = genai.Client(http_options={"api_version": "v1beta"})
        return self._client

    async def start(self) -> None:
        """Open the Gemini Live API session and start receiving server events."""
        if self._session is not None:
            return
        client = self._get_client()
        self._session_cm = client.aio.live.connect(model=self._model, config=build_live_config())
        self._session = await self._session_cm.__aenter__()
        self._receive_task = asyncio.create_task(self._receive_loop())
        await self._emit(HudStateMessage(state="listening"))

    async def stop(self) -> None:
        """Close the Gemini Live API session and cancel background tasks."""
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

    async def _close_session_cm(self) -> None:
        session_cm = self._session_cm
        self._session_cm = None
        self._session = None
        if session_cm is not None:
            try:
                await session_cm.__aexit__(None, None, None)
            except Exception:
                logger.debug("Ignoring error while closing stale Live session", exc_info=True)

    async def _send_realtime_with_reconnect(self, *, allow_restart: bool, **kwargs) -> None:
        if self._session is None:
            if not allow_restart:
                return
            await self.start()
        if self._session is None:
            return
        try:
            await self._session.send_realtime_input(**kwargs)
        except Exception as exc:
            if not allow_restart:
                logger.debug("Live session send failed (%s); resetting stale session", exc)
                await self._close_session_cm()
                return
            logger.warning("Live session send failed (%s); reconnecting and retrying", exc)
            await self._close_session_cm()
            await self.start()
            if self._session is not None:
                await self._session.send_realtime_input(**kwargs)

    async def handle_upstream(self, message: UpstreamMessage) -> None:
        """Route an incoming macos-app message to the active Live session."""
        if isinstance(message, SessionControlMessage):
            if message.action == "start_session":
                await self.start()
            elif message.action == "stop_session":
                await self.stop()
            elif message.action == "barge_in_manual":
                await self._emit(BargeInMessage(reason="manual"))
            return

        if isinstance(message, ScreenContextMessage):
            self._latest_screen = message
            if self._session is None:
                return
            jpeg_bytes = base64.b64decode(message.jpeg_b64)
            await self._send_realtime_with_reconnect(
                allow_restart=False,
                video=types.Blob(data=jpeg_bytes, mime_type="image/jpeg"),
            )
            summary = summarize_ax_elements(message)
            if summary and summary != self._last_ax_summary and self._session is not None:
                self._last_ax_summary = summary
                await self._send_realtime_with_reconnect(
                    allow_restart=False,
                    text=f"[UI Context]\n{summary}",
                )
            return

        if isinstance(message, AudioUpMessage):
            if self._session is None:
                return
            pcm_bytes = base64.b64decode(message.pcm_b64)
            await self._send_realtime_with_reconnect(
                allow_restart=False,
                audio=types.Blob(data=pcm_bytes, mime_type="audio/pcm;rate=16000"),
            )
            return

        if isinstance(message, TextUpMessage):
            await self._emit(HudStateMessage(state="thinking"))
            await self._send_realtime_with_reconnect(
                allow_restart=True,
                text=message.text,
            )

    async def _receive_loop(self) -> None:
        session = self._session
        assert session is not None
        try:
            async for response in session.receive():
                await self.process_live_response(response)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Error in Gemini Live receive loop")
            await self._emit(HudStateMessage(state="idle", transcript_snippet="Live session disconnected"))
        finally:
            if self._session is session:
                await self._close_session_cm()
            if self._receive_task is asyncio.current_task():
                self._receive_task = None

    async def process_live_response(self, response) -> None:
        """Process tool calls and server content from a Gemini Live API event."""
        if getattr(response, "tool_call", None) and response.tool_call.function_calls:
            await self._handle_tool_calls(response.tool_call.function_calls)

        content = getattr(response, "server_content", None)
        if not content:
            return

        if getattr(content, "interrupted", False) is True:
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

        out_tx = getattr(content, "output_transcription", None)
        if out_tx and getattr(out_tx, "text", None):
            await self._emit(HudStateMessage(state="listening", transcript_snippet=out_tx.text))

    async def _handle_tool_calls(self, function_calls) -> None:
        responses: list[types.FunctionResponse] = []
        for call in function_calls:
            command, response = resolve_tool_call(call, self._latest_screen)
            if command is not None:
                await self._emit(command)
            responses.append(response)

        if self._session is not None and responses:
            await self._session.send_tool_response(function_responses=responses)
