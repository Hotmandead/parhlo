"""Strict Pydantic v2 schemas for the macos-app <-> agent-sidecar WebSocket protocol."""

from typing import Annotated, Literal
from pydantic import BaseModel, Field


class PixelRect(BaseModel):
    """Screen rectangle in top-left origin pixel coordinates."""

    x: int
    y: int
    width: int = Field(ge=1)
    height: int = Field(ge=1)


class Point2D(BaseModel):
    """2D point in top-left origin pixel coordinates."""

    x: int
    y: int


class AXElementBounds(BaseModel):
    """Visible macOS Accessibility element metadata and bounding box."""

    role: str
    title: str | None = None
    description: str | None = None
    value: str | None = None
    x: int
    y: int
    width: int = Field(ge=0)
    height: int = Field(ge=0)


class DetectedRectBounds(BaseModel):
    """Vision-detected UI rectangle fallback in top-left origin pixel coordinates."""

    x: int
    y: int
    width: int = Field(ge=1)
    height: int = Field(ge=1)
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)


class DocumentTableSummary(BaseModel):
    """Bounded structured table extracted from an on-screen document."""

    rows: list[list[str]] = Field(default_factory=list, max_length=12)


class DocumentContext(BaseModel):
    """Redacted, bounded document structure extracted from on-screen content."""

    title: str | None = Field(default=None, max_length=160)
    paragraphs: list[str] = Field(default_factory=list, max_length=16)
    tables: list[DocumentTableSummary] = Field(default_factory=list, max_length=2)
    truncated: bool = False


class SessionControlMessage(BaseModel):
    """Upstream session lifecycle control message from macos-app."""

    type: Literal["session_control"] = "session_control"
    action: Literal["start_session", "stop_session", "barge_in_manual"]


class ScreenContextMessage(BaseModel):
    """Upstream redacted JPEG screen frame and AXUIElement snapshot."""

    type: Literal["screen_context"] = "screen_context"
    screen_width: int = Field(gt=0)
    screen_height: int = Field(gt=0)
    scale_factor: float = Field(default=1.0, gt=0)
    jpeg_b64: str
    ax_elements: list[AXElementBounds] = Field(default_factory=list)
    frontmost_bundle_id: str | None = None
    detected_rects: list[DetectedRectBounds] = Field(default_factory=list)
    document_context: DocumentContext | None = None


class AudioUpMessage(BaseModel):
    """Upstream 16 kHz 16-bit mono PCM microphone audio chunk."""

    type: Literal["audio_up"] = "audio_up"
    pcm_b64: str


class TextUpMessage(BaseModel):
    """Upstream typed or dictated text prompt from the Assistant Drawer."""

    type: Literal["text_up"] = "text_up"
    text: str = Field(min_length=1)


UpstreamMessage = Annotated[
    SessionControlMessage | ScreenContextMessage | AudioUpMessage | TextUpMessage,
    Field(discriminator="type"),
]


class DrawCommandMessage(BaseModel):
    """Downstream visual annotation command for the macOS overlay."""

    type: Literal["draw_command"] = "draw_command"
    command_id: str
    action: Literal[
        "highlight_region",
        "point_arrow",
        "show_step_callout",
        "clear_annotations",
    ]
    pixel_rect: PixelRect | None = None
    from_point: Point2D | None = None
    to_point: Point2D | None = None
    label: str | None = None
    step_number: int | None = None
    explanation: str | None = None
    color: str = "#3B82F6"
    style: str | None = None
    matched_ax_role: str | None = None
    matched_ax_title: str | None = None


class AudioDownMessage(BaseModel):
    """Downstream 24 kHz 16-bit mono PCM Gemini voice chunk."""

    type: Literal["audio_down"] = "audio_down"
    pcm_b64: str


class BargeInMessage(BaseModel):
    """Downstream interruption signal to flush audio playback and fade overlays."""

    type: Literal["barge_in"] = "barge_in"
    reason: Literal["vad_interrupted", "manual"] = "vad_interrupted"


class HudStateMessage(BaseModel):
    """Downstream HUD status and live transcript update."""

    type: Literal["hud_state"] = "hud_state"
    state: Literal["idle", "listening", "thinking", "drawing", "privacy_paused"]
    transcript_snippet: str | None = None


DownstreamMessage = Annotated[
    DrawCommandMessage | AudioDownMessage | BargeInMessage | HudStateMessage,
    Field(discriminator="type"),
]
