"""Resolve Gemini Live spatial tool calls into DrawCommandMessages."""

import logging
import math
import uuid

from google.genai import types

from sidecar.grounding import (
    denormalize_box,
    rect_center,
    refine_with_ax_elements,
    refine_with_detected_rects,
)
from sidecar.schemas import (
    AXElementBounds,
    DetectedRectBounds,
    DrawCommandMessage,
    PixelRect,
    Point2D,
    ScreenContextMessage,
)

logger = logging.getLogger(__name__)


def _opt_str(value: object) -> str | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return str(value)
    return None


def _str_or_default(value: object, default: str) -> str:
    if isinstance(value, str):
        stripped = value.strip()
        if stripped:
            return stripped
    return default


def _normalize_highlight_style(value: object) -> str:
    if isinstance(value, str) and value.strip().lower() in ("pulse", "spotlight"):
        return "pulse"
    return "box"


def _parse_box(raw_box: object, field_name: str, screen_w: int, screen_h: int) -> PixelRect:
    if not isinstance(raw_box, (list, tuple)):
        raise ValueError(f"Missing or invalid '{field_name}': expected 4-element list")
    return denormalize_box(raw_box, screen_w, screen_h)


def _parse_step_number(raw_step: object) -> int:
    if raw_step is None or isinstance(raw_step, bool):
        raise ValueError("Missing or invalid 'step_number'")
    if isinstance(raw_step, float) and not math.isfinite(raw_step):
        raise ValueError(f"Invalid 'step_number': {raw_step!r}")
    try:
        step = int(raw_step)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid 'step_number': {raw_step!r}") from exc
    if step < 1:
        raise ValueError(f"'step_number' must be >= 1, got {step}")
    return step


def _default_arrow_origin(to_pt: Point2D, screen_w: int, screen_h: int) -> Point2D:
    """Choose a visible on-screen arrow origin offset from `to_pt` when `from_box_2d` is omitted."""
    dx = -120 if to_pt.x >= 140 else 120
    dy = -80 if to_pt.y >= 100 else 80
    fx = max(0, min(screen_w - 1, to_pt.x + dx))
    fy = max(0, min(screen_h - 1, to_pt.y + dy))
    if fx == to_pt.x and fy == to_pt.y:
        fx = max(0, min(screen_w - 1, to_pt.x + (1 if to_pt.x == 0 else -1)))
    return Point2D(x=fx, y=fy)


def _snap_rect(
    raw_rect: PixelRect,
    ax_elements: list[AXElementBounds],
    detected_rects: list[DetectedRectBounds],
    target_label: str | None = None,
) -> tuple[PixelRect, str | None, str | None]:
    snapped, matched_ax = refine_with_ax_elements(
        raw_rect, ax_elements, target_label=target_label
    )
    if matched_ax is not None:
        return snapped, matched_ax.role, matched_ax.title
    if detected_rects:
        snapped_det, matched_det = refine_with_detected_rects(raw_rect, detected_rects)
        if matched_det is not None:
            return snapped_det, "vision_rect", None
    return snapped, None, None


def _error_response(call_id: str | None, name: str, reason: str) -> types.FunctionResponse:
    return types.FunctionResponse(
        id=call_id,
        name=name,
        response={"status": "error", "error": reason},
    )


def resolve_tool_call(
    call,
    screen: ScreenContextMessage | None,
) -> tuple[DrawCommandMessage | None, types.FunctionResponse]:
    """Convert a Gemini Live function call into a DrawCommandMessage and FunctionResponse."""
    raw_args = getattr(call, "args", None)
    args = raw_args if isinstance(raw_args, dict) else {}
    cmd_id = str(uuid.uuid4())
    call_id = getattr(call, "id", None)
    name = getattr(call, "name", None) or ""
    screen_w = screen.screen_width if screen else 1512
    screen_h = screen.screen_height if screen else 982
    ax_elements: list[AXElementBounds] = screen.ax_elements if screen else []
    detected_rects: list[DetectedRectBounds] = screen.detected_rects if screen else []

    try:
        if name == "clear_annotations":
            command = DrawCommandMessage(
                command_id=cmd_id,
                action="clear_annotations",
                explanation=_opt_str(args.get("reason")),
            )
        elif name == "highlight_region":
            label = _opt_str(args.get("label"))
            raw_rect = _parse_box(args.get("box_2d"), "box_2d", screen_w, screen_h)
            snapped, matched_role, matched_title = _snap_rect(
                raw_rect, ax_elements, detected_rects, target_label=label
            )
            command = DrawCommandMessage(
                command_id=cmd_id,
                action="highlight_region",
                pixel_rect=snapped,
                label=label,
                style=_normalize_highlight_style(args.get("style")),
                color=_str_or_default(args.get("color"), "#3B82F6"),
                matched_ax_role=matched_role,
                matched_ax_title=matched_title,
            )
        elif name == "point_arrow":
            label = _opt_str(args.get("label"))
            to_raw = _parse_box(args.get("to_box_2d"), "to_box_2d", screen_w, screen_h)
            to_snapped, matched_role, matched_title = _snap_rect(
                to_raw, ax_elements, detected_rects, target_label=label
            )
            to_pt = rect_center(to_snapped)
            raw_from = args.get("from_box_2d")
            if raw_from is not None:
                from_raw = _parse_box(raw_from, "from_box_2d", screen_w, screen_h)
                from_pt = rect_center(from_raw)
            else:
                from_pt = _default_arrow_origin(to_pt, screen_w, screen_h)
            command = DrawCommandMessage(
                command_id=cmd_id,
                action="point_arrow",
                pixel_rect=to_snapped,
                from_point=from_pt,
                to_point=to_pt,
                label=label,
                color=_str_or_default(args.get("color"), "#10B981"),
                matched_ax_role=matched_role,
                matched_ax_title=matched_title,
            )
        elif name == "show_step_callout":
            title = _opt_str(args.get("title"))
            raw_rect = _parse_box(args.get("box_2d"), "box_2d", screen_w, screen_h)
            step_number = _parse_step_number(args.get("step_number"))
            snapped, matched_role, matched_title = _snap_rect(
                raw_rect, ax_elements, detected_rects, target_label=title
            )
            command = DrawCommandMessage(
                command_id=cmd_id,
                action="show_step_callout",
                pixel_rect=snapped,
                step_number=step_number,
                label=title,
                explanation=_opt_str(args.get("explanation")),
                color=_str_or_default(args.get("color"), "#3B82F6"),
                matched_ax_role=matched_role,
                matched_ax_title=matched_title,
            )
        else:
            reason = f"Unknown tool: {name!r}"
            logger.warning("Ignoring unknown Live tool call %s", reason)
            return None, _error_response(call_id, name, reason)
    except (ValueError, TypeError) as exc:
        reason = str(exc)
        logger.warning("Malformed tool call %r: %s", name, reason)
        return None, _error_response(call_id, name, reason)

    response = types.FunctionResponse(
        id=call_id,
        name=name,
        response={"status": "rendered", "command_id": cmd_id},
    )
    return command, response
