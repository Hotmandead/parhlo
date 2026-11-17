"""Unit tests for spatial grounding, schemas, NON_BLOCKING tools, and Live session events."""

import asyncio
import base64
import logging
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
    AudioUpMessage,
    BargeInMessage,
    DetectedRectBounds,
    DocumentContext,
    DocumentTableSummary,
    DrawCommandMessage,
    HudStateMessage,
    InputTranscriptMessage,
    PixelRect,
    ScreenContextMessage,
    SessionControlMessage,
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


def test_refine_with_ax_elements_ignores_container_roles():
    raw_rect = PixelRect(x=400, y=100, width=200, height=40)
    ax_elements = [
        AXElementBounds(role="AXWindow", title="Settings", x=0, y=0, width=1440, height=900),
        AXElementBounds(role="AXGroup", title="Settings", x=380, y=90, width=240, height=60),
        AXElementBounds(role="AXScrollArea", title="Settings", x=300, y=80, width=500, height=400),
        AXElementBounds(role="AXWebArea", title="Settings", x=300, y=80, width=500, height=400),
        AXElementBounds(role="AXApplication", title="Settings", x=0, y=0, width=1440, height=900),
        AXElementBounds(role="AXButton", title="Settings", x=405, y=102, width=190, height=36),
    ]

    snapped, matched = refine_with_ax_elements(raw_rect, ax_elements, target_label="Settings")
    assert matched is not None
    assert matched.role == "AXButton"
    assert snapped == PixelRect(x=405, y=102, width=190, height=36)

    # When only container roles exist, do not snap to a container bounding box.
    only_containers = [ax for ax in ax_elements if ax.role != "AXButton"]
    unsnapped, no_match = refine_with_ax_elements(raw_rect, only_containers, target_label="Settings")
    assert no_match is None
    assert unsnapped == raw_rect


def test_overlay_tools_are_non_blocking():
    tools = get_overlay_tools()
    decls = tools[0].function_declarations
    names = [d.name for d in decls]
    assert names == ["highlight_region", "point_arrow", "show_step_callout", "clear_annotations"]
    for decl in decls:
        assert decl.behavior == types.Behavior.NON_BLOCKING
    highlight_decl = decls[0]
    assert highlight_decl.parameters.properties["style"].enum == ["box", "pulse"]


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


def test_tool_dispatcher_guards_malformed_null_and_unknown_tools():
    screen = ScreenContextMessage(
        screen_width=1512,
        screen_height=982,
        jpeg_b64=base64.b64encode(b"jpeg").decode("ascii"),
    )

    # null color + spotlight style normalized to "pulse"
    cmd, resp = resolve_tool_call(
        SimpleNamespace(
            id="c1",
            name="highlight_region",
            args={
                "box_2d": [100, 100, 200, 300],
                "label": "Save",
                "color": None,
                "style": "spotlight",
            },
        ),
        screen,
    )
    assert cmd is not None
    assert cmd.color == "#3B82F6"
    assert cmd.style == "pulse"
    assert resp.response["status"] == "rendered"

    # point_arrow without from_box_2d synthesizes a visible from_point
    arrow_cmd, arrow_resp = resolve_tool_call(
        SimpleNamespace(
            id="c2",
            name="point_arrow",
            args={"to_box_2d": [200, 400, 260, 500], "label": "Click", "color": None},
        ),
        screen,
    )
    assert arrow_cmd is not None
    assert arrow_cmd.color == "#10B981"
    assert arrow_cmd.to_point is not None
    assert arrow_cmd.from_point is not None
    assert arrow_cmd.from_point != arrow_cmd.to_point
    assert arrow_resp.response["status"] == "rendered"

    # Malformed cases: missing box_2d, wrong type, non-numeric, invalid step_number, unknown tool
    malformed_calls = [
        SimpleNamespace(id="e1", name="highlight_region", args={"label": "Missing box"}),
        SimpleNamespace(id="e2", name="highlight_region", args={"box_2d": [100, 200], "label": "Short"}),
        SimpleNamespace(id="e3", name="highlight_region", args={"box_2d": "1234", "label": "String box"}),
        SimpleNamespace(id="e4", name="highlight_region", args={"box_2d": [1, "x", 3, 4]}),
        SimpleNamespace(id="e5", name="point_arrow", args={"to_box_2d": None, "label": "Null target"}),
        SimpleNamespace(
            id="e6",
            name="show_step_callout",
            args={"box_2d": [10, 10, 50, 50], "step_number": None, "title": "Step"},
        ),
        SimpleNamespace(
            id="e7",
            name="show_step_callout",
            args={"box_2d": [10, 10, 50, 50], "step_number": "abc", "title": "Step"},
        ),
        SimpleNamespace(id="e8", name="unknown_tool", args={"foo": "bar"}),
    ]
    for bad_call in malformed_calls:
        bad_cmd, bad_resp = resolve_tool_call(bad_call, screen)
        assert bad_cmd is None
        assert bad_resp.id == bad_call.id
        assert bad_resp.name == bad_call.name
        assert bad_resp.response["status"] == "error"
        assert bad_resp.response["error"]


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
async def test_text_up_reconnects_with_screen_context_after_stale_session_disconnect():
    emitted = []
    fresh_realtime_inputs = []
    fresh_client_contents = []
    connect_calls = 0

    async def emit(msg):
        emitted.append(msg)

    class StaleSession:
        async def send_realtime_input(self, **kwargs):
            return None

        async def send_client_content(self, *, turns=None, turn_complete=True):
            raise RuntimeError("1008 Session closed due to client inactivity.")

        async def receive(self):
            if False:
                yield None

    class FreshSession:
        async def send_realtime_input(self, **kwargs):
            fresh_realtime_inputs.append(kwargs)

        async def send_client_content(self, *, turns=None, turn_complete=True):
            fresh_client_contents.append((turns, turn_complete))

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
    await manager.handle_upstream(
        ScreenContextMessage(
            screen_width=1440,
            screen_height=900,
            jpeg_b64=base64.b64encode(b"screen-jpeg").decode("ascii"),
            frontmost_bundle_id="com.apple.Safari",
            ax_elements=[
                AXElementBounds(role="AXButton", title="Submit", x=100, y=100, width=80, height=30)
            ],
            document_context=DocumentContext(title="Form Page", paragraphs=["Fill details."]),
        )
    )
    assert manager._screen_sent_in_session is True

    await manager.handle_upstream(TextUpMessage(text="Where is Submit?"))

    assert connect_calls == 2
    # Full screen + UI + Document context must be resent on the fresh Live session
    assert len(fresh_realtime_inputs) == 3
    assert fresh_realtime_inputs[0]["video"].data == b"screen-jpeg"
    assert fresh_realtime_inputs[1]["text"].startswith("[UI Context]\n")
    assert fresh_realtime_inputs[2]["text"].startswith("[Document Context]\n")
    assert len(fresh_client_contents) == 1
    turns, turn_complete = fresh_client_contents[0]
    assert turn_complete is True
    assert turns.role == "user"
    assert turns.parts[0].text == "Where is Submit?"
    await manager.stop()


@pytest.mark.asyncio
async def test_screen_context_before_text_up_is_forwarded_on_lazy_session_start():
    emitted = []
    sent_inputs = []
    sent_client_contents = []

    async def emit(msg):
        emitted.append(msg)

    class FakeSession:
        async def send_realtime_input(self, **kwargs):
            sent_inputs.append(kwargs)

        async def send_client_content(self, *, turns=None, turn_complete=True):
            sent_client_contents.append((turns, turn_complete))

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
    assert len(sent_inputs) == 3
    assert "video" in sent_inputs[0]
    assert sent_inputs[0]["video"].data == b"fake-jpeg-bytes"
    assert sent_inputs[0]["video"].mime_type == "image/jpeg"
    assert sent_inputs[1]["text"].startswith("[UI Context]\n")
    assert "Reload" in sent_inputs[1]["text"]
    assert sent_inputs[2]["text"].startswith("[Document Context]\n")
    assert "Parhlo Architecture Spec" in sent_inputs[2]["text"]

    assert len(sent_client_contents) == 1
    turns, turn_complete = sent_client_contents[0]
    assert turn_complete is True
    assert turns.role == "user"
    assert turns.parts[0].text == "What do you see on the screen?"

    await manager.stop()


@pytest.mark.asyncio
async def test_active_session_audio_reconnects_and_manual_barge_in_signals_session():
    emitted = []
    sent_audio = []
    client_contents = []
    connect_calls = 0

    async def emit(msg):
        emitted.append(msg)

    class FailingAudioSession:
        async def send_realtime_input(self, **kwargs):
            if "audio" in kwargs:
                raise RuntimeError("1008 closed")

        async def send_client_content(self, *, turns=None, turn_complete=True):
            client_contents.append((turns, turn_complete))

        async def receive(self):
            await asyncio.sleep(10)
            if False:
                yield None

    class HealthySession:
        async def send_realtime_input(self, **kwargs):
            if "audio" in kwargs:
                sent_audio.append(kwargs["audio"].data)

        async def send_client_content(self, *, turns=None, turn_complete=True):
            client_contents.append((turns, turn_complete))

        async def receive(self):
            await asyncio.sleep(10)
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
            return FakeSessionCM(FailingAudioSession() if connect_calls == 1 else HealthySession())

    manager = GeminiLiveSessionManager(
        emit=emit,
        client=SimpleNamespace(aio=SimpleNamespace(live=FakeLive())),
    )

    await manager.handle_upstream(SessionControlMessage(action="start_session"))
    assert manager._wants_active_session is True

    pcm_b64 = base64.b64encode(b"\x00\x01\x02\x03").decode("ascii")
    await manager.handle_upstream(AudioUpMessage(pcm_b64=pcm_b64))
    assert connect_calls == 2
    assert sent_audio == [b"\x00\x01\x02\x03"]

    await manager.handle_upstream(SessionControlMessage(action="barge_in_manual"))
    assert any(isinstance(m, BargeInMessage) and m.reason == "manual" for m in emitted)
    assert (None, False) in client_contents

    await manager.handle_upstream(SessionControlMessage(action="stop_session"))
    assert manager._wants_active_session is False
    # Subsequent audio after stop_session must NOT reconnect
    await manager.handle_upstream(AudioUpMessage(pcm_b64=pcm_b64))
    assert connect_calls == 2


@pytest.mark.asyncio
async def test_output_transcription_preserves_drawing_state_and_turn_complete(caplog):
    emitted = []

    async def emit(msg):
        emitted.append(msg)

    class FakeSession:
        async def send_tool_response(self, function_responses):
            raise RuntimeError("socket closed during tool response")

        async def receive(self):
            if False:
                yield None

    manager = GeminiLiveSessionManager(emit=emit)
    manager._session = FakeSession()

    # 1. Drawing tool call sets active drawings, even if send_tool_response raises
    with caplog.at_level(logging.WARNING):
        await manager.process_live_response(
            SimpleNamespace(
                tool_call=SimpleNamespace(
                    function_calls=[
                        SimpleNamespace(
                            id="call-draw",
                            name="highlight_region",
                            args={"box_2d": [100, 100, 200, 200], "label": "Target"},
                        )
                    ]
                ),
                go_away=SimpleNamespace(time_left="30s"),
                server_content=SimpleNamespace(
                    input_transcription=SimpleNamespace(text="Where do I click?"),
                    output_transcription=SimpleNamespace(text="Click the Target button."),
                    turn_complete=True,
                ),
            )
        )

    assert "GoAway" in caplog.text
    input_tx_events = [m for m in emitted if isinstance(m, InputTranscriptMessage)]
    assert input_tx_events == [InputTranscriptMessage(text="Where do I click?", is_final=False)]
    hud_events = [m for m in emitted if isinstance(m, HudStateMessage)]
    # Caption and turn_complete must both preserve "drawing" while annotations exist
    assert hud_events[0] == HudStateMessage(state="drawing", transcript_snippet="Click the Target button.")
    assert hud_events[1] == HudStateMessage(state="drawing", transcript_snippet=None)

    # 2. clear_annotations resets active drawings, so next transcription & turn_complete transition cleanly
    emitted.clear()
    await manager.process_live_response(
        SimpleNamespace(
            tool_call=SimpleNamespace(
                function_calls=[
                    SimpleNamespace(id="call-clear", name="clear_annotations", args={"reason": "done"})
                ]
            ),
            server_content=SimpleNamespace(
                output_transcription=SimpleNamespace(text="All done."),
                generation_complete=True,
            ),
        )
    )
    hud_events_after_clear = [m for m in emitted if isinstance(m, HudStateMessage)]
    assert hud_events_after_clear[0] == HudStateMessage(state="listening", transcript_snippet="All done.")
    assert hud_events_after_clear[1] == HudStateMessage(state="idle", transcript_snippet=None)


@pytest.mark.asyncio
async def test_clean_receive_loop_exit_emits_idle():
    emitted = []

    async def emit(msg):
        emitted.append(msg)

    class ShortSession:
        async def receive(self):
            if False:
                yield None

    class FakeSessionCM:
        async def __aenter__(self):
            return ShortSession()

        async def __aexit__(self, exc_type, exc, tb):
            return False

    fake_client = SimpleNamespace(
        aio=SimpleNamespace(live=SimpleNamespace(connect=lambda model, config: FakeSessionCM()))
    )
    manager = GeminiLiveSessionManager(emit=emit, client=fake_client)
    await manager.start()
    # Allow _receive_loop task to run to clean completion
    await asyncio.sleep(0)
    await asyncio.sleep(0)

    assert manager._session is None
    assert emitted == [
        HudStateMessage(state="listening"),
        HudStateMessage(state="idle"),
    ]


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


@pytest.mark.asyncio
async def test_periodic_screen_context_does_not_send_realtime_text_turns():
    emitted = []
    realtime_inputs = []

    async def emit(msg):
        emitted.append(msg)

    class FakeSession:
        async def send_realtime_input(self, **kwargs):
            realtime_inputs.append(kwargs)

        async def send_client_content(self, *, turns=None, turn_complete=True):
            return None

        async def receive(self):
            await asyncio.sleep(10)
            if False:
                yield None

    class FakeSessionCM:
        async def __aenter__(self):
            return FakeSession()

        async def __aexit__(self, exc_type, exc, tb):
            return False

    fake_client = SimpleNamespace(
        aio=SimpleNamespace(live=SimpleNamespace(connect=lambda model, config: FakeSessionCM()))
    )
    manager = GeminiLiveSessionManager(emit=emit, client=fake_client)
    await manager.handle_upstream(SessionControlMessage(action="start_session"))

    # Periodic ScreenContextMessage updates must stream video only, never realtime text prompts.
    await manager.handle_upstream(
        ScreenContextMessage(
            screen_width=1440,
            screen_height=900,
            jpeg_b64=base64.b64encode(b"frame-1").decode("ascii"),
            ax_elements=[AXElementBounds(role="AXButton", title="Run", x=10, y=10, width=50, height=24)],
            document_context=DocumentContext(title="Doc 1", paragraphs=["Changed paragraph"]),
        )
    )
    assert len(realtime_inputs) == 1
    assert "video" in realtime_inputs[0]
    assert all("text" not in item for item in realtime_inputs)

    # Explicit TextUpMessage flushes the changed UI/Document context along with the user turn.
    await manager.handle_upstream(TextUpMessage(text="What changed?"))
    assert any(item.get("text", "").startswith("[UI Context]\n") for item in realtime_inputs)
    assert any(item.get("text", "").startswith("[Document Context]\n") for item in realtime_inputs)

    await manager.stop()
