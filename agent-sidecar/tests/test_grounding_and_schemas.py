"""Unit tests for spatial grounding, schemas, NON_BLOCKING tools, and Live session events."""

import base64
from types import SimpleNamespace

from google.genai import types
from pydantic import TypeAdapter
import pytest

from sidecar.grounding import compute_iou, denormalize_box, refine_with_ax_elements
from sidecar.live_session import (
    GeminiLiveSessionManager,
    summarize_ax_elements,
    summarize_document_context,
)
from sidecar.schemas import (
    AXElementBounds,
    AudioDownMessage,
    BargeInMessage,
    DetectedRectBounds,
    DocumentContext,
    DocumentTableSummary,
    DrawCommandMessage,
    PixelRect,
    ScreenContextMessage,
    TextUpMessage,
    UpstreamMessage,
)
from sidecar.tool_dispatcher import resolve_tool_call
from sidecar.tools import get_overlay_tools


def test_denormalize_box_standard_and_retina_dimensions():
    rect = denormalize_box([100, 200, 300, 500], screen_width=1512, screen_height=982)
    assert rect == PixelRect(x=302, y=98, width=454, height=196)

    rect_hd = denormalize_box([0, 0, 500, 500], screen_width=1920, screen_height=1080)
    assert rect_hd == PixelRect(x=0, y=0, width=960, height=540)


def test_denormalize_box_clamping_and_inverted_coordinates():
    clamped = denormalize_box([-50, 1200, 500, 900], screen_width=1000, screen_height=1000)
    # Clamped: [-50->0, 1200->999, 500, 900] -> x inverted (900..999), y (0..500)
    assert clamped == PixelRect(x=900, y=0, width=99, height=500)


def test_refine_with_ax_elements_snaps_on_iou_and_label():
    raw_rect = PixelRect(x=390, y=95, width=220, height=34)
    ax_elements = [
        AXElementBounds(role="AXButton", title="Cancel", x=50, y=50, width=80, height=28),
        AXElementBounds(role="AXTextField", title="Search files", x=400, y=100, width=200, height=28),
    ]
    iou = compute_iou(raw_rect, PixelRect(x=400, y=100, width=200, height=28))
    assert iou > 0.6

    snapped, matched = refine_with_ax_elements(raw_rect, ax_elements, target_label="Search files")
    assert matched is not None
    assert matched.role == "AXTextField"
    assert snapped == PixelRect(x=400, y=100, width=200, height=28)


def test_overlay_tools_are_non_blocking():
    tools = get_overlay_tools()
    decls = tools[0].function_declarations
    names = [d.name for d in decls]
    assert names == ["highlight_region", "point_arrow", "show_step_callout", "clear_annotations"]
    for decl in decls:
        assert decl.behavior == types.Behavior.NON_BLOCKING


def test_upstream_message_schema_parsing():
    adapter = TypeAdapter(UpstreamMessage)
    raw = (
        '{"type":"screen_context","screen_width":1512,"screen_height":982,'
        '"scale_factor":2.0,"jpeg_b64":"Zm9v","ax_elements":[]}'
    )
    msg = adapter.validate_json(raw)
    assert isinstance(msg, ScreenContextMessage)
    assert msg.screen_width == 1512
    assert msg.scale_factor == 2.0

    text_msg = adapter.validate_json('{"type":"text_up","text":"Where is the filter bar?"}')
    assert text_msg.type == "text_up"
    assert text_msg.text == "Where is the filter bar?"


@pytest.mark.asyncio
async def test_live_session_processes_tool_call_audio_and_barge_in():
    emitted = []

    async def emit(msg):
        emitted.append(msg)

    sent_tool_responses = []

    class FakeSession:
        async def send_realtime_input(self, **kwargs):
            return None

        async def send_tool_response(self, function_responses):
            sent_tool_responses.extend(function_responses)

    manager = GeminiLiveSessionManager(emit=emit)
    manager._session = FakeSession()
    await manager.handle_upstream(
        ScreenContextMessage(
            screen_width=1000,
            screen_height=1000,
            jpeg_b64=base64.b64encode(b"jpeg").decode("ascii"),
            ax_elements=[
                AXElementBounds(role="AXButton", title="Filter", x=100, y=100, width=100, height=40)
            ],
        )
    )

    fake_event = SimpleNamespace(
        tool_call=SimpleNamespace(
            function_calls=[
                SimpleNamespace(
                    id="call-1",
                    name="highlight_region",
                    args={"box_2d": [100, 100, 140, 200], "label": "Filter"},
                )
            ]
        ),
        server_content=SimpleNamespace(
            interrupted=True,
            model_turn=SimpleNamespace(
                parts=[SimpleNamespace(inline_data=SimpleNamespace(data=b"\x01\x02\x03\x04"))]
            ),
            output_transcription=None,
        ),
    )

    await manager.process_live_response(fake_event)

    assert any(isinstance(m, DrawCommandMessage) and m.matched_ax_title == "Filter" for m in emitted)
    assert any(isinstance(m, BargeInMessage) and m.reason == "vad_interrupted" for m in emitted)
    assert any(isinstance(m, AudioDownMessage) for m in emitted)
    assert len(sent_tool_responses) == 1
    assert sent_tool_responses[0].name == "highlight_region"


@pytest.mark.asyncio
async def test_text_up_reconnects_after_stale_session_disconnect():
    emitted = []
    sent_texts = []
    connect_calls = 0

    async def emit(msg):
        emitted.append(msg)

    class StaleSession:
        async def send_realtime_input(self, **kwargs):
            raise RuntimeError("1008 Session closed due to client inactivity.")

        async def receive(self):
            if False:
                yield None

    class FreshSession:
        async def send_realtime_input(self, **kwargs):
            sent_texts.append(kwargs.get("text"))

        async def receive(self):
            if False:
                yield None

    class FakeSessionCM:
        def __init__(self, session):
            self._session = session

        async def __aenter__(self):
            return self._session

        async def __aexit__(self, exc_type, exc, tb):
            return False

    class FakeLive:
        def connect(self, model, config):
            nonlocal connect_calls
            connect_calls += 1
            return FakeSessionCM(StaleSession() if connect_calls == 1 else FreshSession())

    fake_client = SimpleNamespace(aio=SimpleNamespace(live=FakeLive()))
    manager = GeminiLiveSessionManager(emit=emit, client=fake_client)

    await manager.start()
    await manager.handle_upstream(TextUpMessage(text="What's the weather?"))

    assert connect_calls == 2
    assert sent_texts == ["What's the weather?"]
    await manager.stop()


@pytest.mark.asyncio
async def test_screen_context_before_text_up_is_forwarded_on_lazy_session_start():
    emitted = []
    sent_inputs = []

    async def emit(msg):
        emitted.append(msg)

    class FakeSession:
        async def send_realtime_input(self, **kwargs):
            sent_inputs.append(kwargs)

        async def receive(self):
            if False:
                yield None

    class FakeSessionCM:
        async def __aenter__(self):
            return FakeSession()

        async def __aexit__(self, exc_type, exc, tb):
            return False

    class FakeLive:
        def connect(self, model, config):
            return FakeSessionCM()

    fake_client = SimpleNamespace(aio=SimpleNamespace(live=FakeLive()))
    manager = GeminiLiveSessionManager(emit=emit, client=fake_client)

    assert manager._session is None

    screen_msg = ScreenContextMessage(
        screen_width=1440,
        screen_height=900,
        jpeg_b64=base64.b64encode(b"fake-jpeg-bytes").decode("ascii"),
        frontmost_bundle_id="com.apple.Safari",
        ax_elements=[
            AXElementBounds(role="AXButton", title="Reload", x=120, y=60, width=80, height=28)
        ],
        document_context=DocumentContext(
            title="Parhlo Architecture Spec",
            paragraphs=["Native macOS capture and on-device OCR redaction."],
            tables=[DocumentTableSummary(rows=[["Phase", "Status"], ["5", "Active"]])],
        ),
    )

    # Receive ScreenContextMessage while _session is still None
    await manager.handle_upstream(screen_msg)
    assert sent_inputs == []
    assert manager._screen_sent_in_session is False

    # Now TextUpMessage lazily starts the session and must forward the cached screen context first
    await manager.handle_upstream(TextUpMessage(text="What do you see on the screen?"))

    assert manager._screen_sent_in_session is True
    assert len(sent_inputs) == 4
    assert "video" in sent_inputs[0]
    assert sent_inputs[0]["video"].data == b"fake-jpeg-bytes"
    assert sent_inputs[0]["video"].mime_type == "image/jpeg"
    assert sent_inputs[1]["text"].startswith("[UI Context]\n")
    assert "Reload" in sent_inputs[1]["text"]
    assert sent_inputs[2]["text"].startswith("[Document Context]\n")
    assert "Parhlo Architecture Spec" in sent_inputs[2]["text"]
    assert sent_inputs[3]["text"] == "What do you see on the screen?"

    await manager.stop()


def test_detected_rects_and_document_context_parsing_and_fallback_grounding():
    adapter = TypeAdapter(UpstreamMessage)
    raw = (
        '{"type":"screen_context","screen_width":1000,"screen_height":1000,'
        '"scale_factor":2.0,"jpeg_b64":"Zm9v","ax_elements":[],'
        '"detected_rects":[{"x":200,"y":300,"width":150,"height":50,"confidence":0.92}],'
        '"document_context":{"title":"Quarterly Report","paragraphs":["Revenue grew 18%."],'
        '"tables":[{"rows":[["Q1","Q2"],["10M","12M"]]}],"truncated":false}}'
    )
    msg = adapter.validate_json(raw)
    assert isinstance(msg, ScreenContextMessage)
    assert len(msg.detected_rects) == 1
    assert msg.detected_rects[0].confidence == pytest.approx(0.92)
    assert msg.document_context is not None
    assert msg.document_context.title == "Quarterly Report"

    ax_summary = summarize_ax_elements(msg)
    assert "vision_rect @ (200,300,150x50)" in ax_summary

    doc_summary = summarize_document_context(msg)
    assert "Quarterly Report" in doc_summary
    assert "Revenue grew 18%." in doc_summary
    assert "Q1 | Q2" in doc_summary

    call = SimpleNamespace(
        id="call-vision-1",
        name="highlight_region",
        args={"box_2d": [295, 195, 355, 355], "label": "Detected Box"},
    )
    command, response = resolve_tool_call(call, msg)
    assert command is not None
    assert command.matched_ax_role == "vision_rect"
    assert command.matched_ax_title is None
    assert command.pixel_rect == PixelRect(x=200, y=300, width=150, height=50)
    assert response.name == "highlight_region"
