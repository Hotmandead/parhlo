"""Gemini Live API NON_BLOCKING FunctionDeclaration schemas for visual overlays."""

from google.genai import types

BOX_2D_SCHEMA = types.Schema(
    type=types.Type.ARRAY,
    items=types.Schema(type=types.Type.INTEGER),
    description="Normalized bounding box [ymin, xmin, ymax, xmax] with values in 0-999.",
)


def get_overlay_tools() -> list[types.Tool]:
    """Return the four NON_BLOCKING spatial-grounding FunctionDeclarations."""
    return [
        types.Tool(
            function_declarations=[
                types.FunctionDeclaration(
                    name="highlight_region",
                    description="Highlight a target UI region on the user's macOS screen.",
                    behavior=types.Behavior.NON_BLOCKING,
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "box_2d": BOX_2D_SCHEMA,
                            "label": types.Schema(
                                type=types.Type.STRING,
                                description="Short label for the highlighted UI control.",
                            ),
                            "style": types.Schema(
                                type=types.Type.STRING,
                                description="Visual style: box or spotlight.",
                            ),
                            "color": types.Schema(
                                type=types.Type.STRING,
                                description="Hex color such as #3B82F6.",
                            ),
                        },
                        required=["box_2d", "label"],
                    ),
                ),
                types.FunctionDeclaration(
                    name="point_arrow",
                    description="Draw an animated directional arrow pointing to a UI element.",
                    behavior=types.Behavior.NON_BLOCKING,
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "from_box_2d": BOX_2D_SCHEMA,
                            "to_box_2d": BOX_2D_SCHEMA,
                            "label": types.Schema(
                                type=types.Type.STRING,
                                description="Short caption near the arrow.",
                            ),
                            "color": types.Schema(
                                type=types.Type.STRING,
                                description="Hex color such as #10B981.",
                            ),
                        },
                        required=["to_box_2d", "label"],
                    ),
                ),
                types.FunctionDeclaration(
                    name="show_step_callout",
                    description="Show a numbered step callout card anchored near a UI element.",
                    behavior=types.Behavior.NON_BLOCKING,
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "box_2d": BOX_2D_SCHEMA,
                            "step_number": types.Schema(
                                type=types.Type.INTEGER,
                                description="1-based step index.",
                            ),
                            "title": types.Schema(
                                type=types.Type.STRING,
                                description="Concise step title.",
                            ),
                            "explanation": types.Schema(
                                type=types.Type.STRING,
                                description="Brief explanation shown on the callout card.",
                            ),
                        },
                        required=["box_2d", "step_number", "title", "explanation"],
                    ),
                ),
                types.FunctionDeclaration(
                    name="clear_annotations",
                    description="Clear all active visual annotations from the macOS overlay.",
                    behavior=types.Behavior.NON_BLOCKING,
                    parameters=types.Schema(
                        type=types.Type.OBJECT,
                        properties={
                            "reason": types.Schema(
                                type=types.Type.STRING,
                                description="Optional reason for clearing annotations.",
                            ),
                        },
                    ),
                ),
            ]
        )
    ]
