"""0-999 coordinate denormalization and deterministic AXUIElement bounding-box snapping."""

from difflib import SequenceMatcher
import math
from typing import Sequence

from sidecar.schemas import AXElementBounds, DetectedRectBounds, PixelRect, Point2D

CONTAINER_AX_ROLES: frozenset[str] = frozenset(
    {
        "AXApplication",
        "AXWindow",
        "AXScrollArea",
        "AXWebArea",
        "AXGroup",
    }
)


def denormalize_box(
    box_2d: Sequence[int | float],
    screen_width: int,
    screen_height: int,
) -> PixelRect:
    """Convert `[ymin, xmin, ymax, xmax]` in 0-999 normalized space to PixelRect."""
    if len(box_2d) != 4:
        raise ValueError(f"Expected 4 coordinates [ymin, xmin, ymax, xmax], got {len(box_2d)}")
    if screen_width <= 0 or screen_height <= 0:
        raise ValueError("Screen dimensions must be positive")

    coords: list[int] = []
    for c in box_2d:
        if isinstance(c, bool) or not isinstance(c, (int, float)) or not math.isfinite(c):
            raise ValueError(f"Invalid coordinate value in box_2d: {c!r}")
        coords.append(max(0, min(999, int(c))))

    ymin, xmin, ymax, xmax = coords
    if ymin > ymax:
        ymin, ymax = ymax, ymin
    if xmin > xmax:
        xmin, xmax = xmax, xmin

    x1 = int(xmin / 1000 * screen_width)
    y1 = int(ymin / 1000 * screen_height)
    x2 = int(xmax / 1000 * screen_width)
    y2 = int(ymax / 1000 * screen_height)
    return PixelRect(x=x1, y=y1, width=max(1, x2 - x1), height=max(1, y2 - y1))


def rect_center(rect: PixelRect) -> Point2D:
    """Return the integer center point of a PixelRect."""
    return Point2D(x=rect.x + rect.width // 2, y=rect.y + rect.height // 2)


def compute_iou(a: PixelRect, b: PixelRect) -> float:
    """Compute Intersection-over-Union between two PixelRects."""
    ax2, ay2 = a.x + a.width, a.y + a.height
    bx2, by2 = b.x + b.width, b.y + b.height

    ix1 = max(a.x, b.x)
    iy1 = max(a.y, b.y)
    ix2 = min(ax2, bx2)
    iy2 = min(ay2, by2)

    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0

    inter = (ix2 - ix1) * (iy2 - iy1)
    union = (a.width * a.height) + (b.width * b.height) - inter
    return inter / union if union > 0 else 0.0


def _contains_center(outer: PixelRect, inner: PixelRect) -> bool:
    cx = inner.x + inner.width / 2.0
    cy = inner.y + inner.height / 2.0
    return outer.x <= cx <= (outer.x + outer.width) and outer.y <= cy <= (outer.y + outer.height)


def _label_similarity(target_label: str | None, ax: AXElementBounds) -> float:
    if not target_label:
        return 0.0
    target = target_label.strip().lower()
    if not target:
        return 0.0
    candidates = [c.strip().lower() for c in (ax.title, ax.description, ax.value) if c and c.strip()]
    if not candidates:
        return 0.0
    return max(SequenceMatcher(None, target, c).ratio() for c in candidates)


def refine_with_ax_elements(
    rect: PixelRect,
    ax_elements: Sequence[AXElementBounds],
    target_label: str | None = None,
    iou_threshold: float = 0.35,
) -> tuple[PixelRect, AXElementBounds | None]:
    """Snap a denormalized rect to the best matching AXUIElement when confidence is high."""
    best_ax: AXElementBounds | None = None
    best_score = 0.0

    for ax in ax_elements:
        if ax.role in CONTAINER_AX_ROLES:
            continue
        if ax.width <= 0 or ax.height <= 0:
            continue
        ax_rect = PixelRect(x=ax.x, y=ax.y, width=ax.width, height=ax.height)
        iou = compute_iou(rect, ax_rect)
        label_sim = _label_similarity(target_label, ax)
        center_bonus = 0.15 if (_contains_center(ax_rect, rect) or _contains_center(rect, ax_rect)) else 0.0

        score = iou + (0.45 * label_sim) + center_bonus
        qualified = (iou >= iou_threshold) or (label_sim >= 0.75 and (iou > 0.05 or center_bonus > 0))
        if qualified and score > best_score:
            best_score = score
            best_ax = ax

    if best_ax is None:
        return rect, None

    return (
        PixelRect(x=best_ax.x, y=best_ax.y, width=best_ax.width, height=best_ax.height),
        best_ax,
    )


def refine_with_detected_rects(
    rect: PixelRect,
    detected_rects: Sequence[DetectedRectBounds],
    iou_threshold: float = 0.35,
) -> tuple[PixelRect, DetectedRectBounds | None]:
    """Snap a denormalized rect to the best matching Vision-detected rectangle fallback."""
    best_candidate: DetectedRectBounds | None = None
    best_score = 0.0

    for candidate in detected_rects:
        if candidate.width <= 0 or candidate.height <= 0:
            continue
        cand_rect = PixelRect(
            x=candidate.x,
            y=candidate.y,
            width=candidate.width,
            height=candidate.height,
        )
        iou = compute_iou(rect, cand_rect)
        center_bonus = (
            0.15 if (_contains_center(cand_rect, rect) or _contains_center(rect, cand_rect)) else 0.0
        )
        score = iou + center_bonus + (0.1 * candidate.confidence)
        qualified = (iou >= iou_threshold) or (center_bonus > 0 and iou >= 0.15)
        if qualified and score > best_score:
            best_score = score
            best_candidate = candidate

    if best_candidate is None:
        return rect, None

    return (
        PixelRect(
            x=best_candidate.x,
            y=best_candidate.y,
            width=best_candidate.width,
            height=best_candidate.height,
        ),
        best_candidate,
    )
