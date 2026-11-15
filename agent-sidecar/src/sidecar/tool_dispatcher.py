"""Resolve Gemini Live spatial tool calls into DrawCommandMessages."""

import uuid

from google.genai import types

from sidecar.grounding import denormalize_box, rect_center, refine_with_ax_elements
from sidecar.schemas import AXElementBounds, DrawCommandMessage, ScreenContextMessage


def resolve_tool_call(
    call,
    screen: ScreenContextMessage | None,
) -> tuple[DrawCommandMessage | None, types.FunctionResponse]:
    """Convert a Gemini Live function call into a DrawCommandMessage and FunctionResponse."""
    args = call.args or {}
    cmd_id = str(uuid.uuid4())
    name = call.name
    screen_w = screen.screen_width if screen else 1512
    screen_h = screen.screen_height if screen else 982
    ax_elements: list[AXElementBounds] = screen.ax_elements if screen else []

    command: DrawCommandMessage | None = None

    if name == "clear_annotations":
        command = DrawCommandMessage(
            command_id=cmd_id,
            action="clear_annotations",
            explanation=args.get("reason"),
        )
    elif name == "highlight_region":
        raw_rect = denormalize_box(args["box_2d"], screen_w, screen_h)
        snapped, matched_ax = refine_with_ax_elements(
            raw_rect, ax_elements, target_label=args.get("label")
        )
        command = DrawCommandMessage(
            command_id=cmd_id,
            action="highlight_region",
            pixel_rect=snapped,
            label=args.get("label"),
            style=args.get("style", "box"),
            color=args.get("color", "#3B82F6"),
            matched_ax_role=matched_ax.role if matched_ax else None,
            matched_ax_title=matched_ax.title if matched_ax else None,
        )
    elif name == "point_arrow":
        to_raw = denormalize_box(args["to_box_2d"], screen_w, screen_h)
        to_snapped, matched_ax = refine_with_ax_elements(
            to_raw, ax_elements, target_label=args.get("label")
        )
        from_pt = None
        if args.get("from_box_2d"):
            from_raw = denormalize_box(args["from_box_2d"], screen_w, screen_h)
            from_pt = rect_center(from_raw)
        command = DrawCommandMessage(
            command_id=cmd_id,
            action="point_arrow",
            pixel_rect=to_snapped,
            from_point=from_pt,
            to_point=rect_center(to_snapped),
            label=args.get("label"),
            color=args.get("color", "#10B981"),
            matched_ax_role=matched_ax.role if matched_ax else None,
            matched_ax_title=matched_ax.title if matched_ax else None,
        )
    elif name == "show_step_callout":
        raw_rect = denormalize_box(args["box_2d"], screen_w, screen_h)
        snapped, matched_ax = refine_with_ax_elements(
            raw_rect, ax_elements, target_label=args.get("title")
        )
        command = DrawCommandMessage(
            command_id=cmd_id,
            action="show_step_callout",
            pixel_rect=snapped,
            step_number=int(args["step_number"]),
            label=args.get("title"),
            explanation=args.get("explanation"),
            matched_ax_role=matched_ax.role if matched_ax else None,
            matched_ax_title=matched_ax.title if matched_ax else None,
        )

    response = types.FunctionResponse(
        id=call.id,
        name=name,
        response={"status": "rendered", "command_id": cmd_id},
    )
    return command, response
