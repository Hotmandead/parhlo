---
name: overlay-hud
description: Rules for borderless .nonactivatingPanel NSPanel overlays, window levels, dynamic ignoresMouseEvents toggling, and Vision-to-NSScreen coordinate conversion.
---

# Overlay HUD & NSPanel Rules

## 1. Borderless `.nonactivatingPanel` NSPanel Subclass
- All floating HUDs, notch panels, and screen annotation overlays must subclass `NSPanel` and be isolated to `@MainActor`.
- Required `styleMask`: `[.borderless, .nonactivatingPanel]` so clicking or displaying the HUD never steals focus or activates Parhlo over the user's foreground application.
- Override focus properties:
  - `override var canBecomeKey: Bool { false }` (or `true` only when a text input field inside the HUD explicitly requests keyboard focus).
  - `override var canBecomeMain: Bool { false }`
- Visual & window-server hygiene:
  - `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` (for full-screen annotation canvases).
  - `sharingType = .none` as defense-in-depth alongside `SCContentFilter` exclusion.
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`.

## 2. Window Levels
- Use `.floating` for standard non-intrusive assistant HUDs and annotation overlays.
- Use `.statusBar` (or `.screenSaver` only when strictly required above menu-bar/notch chrome) for notch-anchored controls that must sit above standard floating windows.

## 3. Dynamic `ignoresMouseEvents` Toggling
- Full-screen annotation overlays must default to `ignoresMouseEvents = true` so all clicks, scrolls, and drags pass through to underlying applications.
- For interactive HUD regions (e.g., dismiss buttons, Ask Parhlo input bar, or hoverable notch pill):
  - Track pointer position or SwiftUI/AppKit hover regions (`NSTrackingArea` / hit-testing against known interactive frames).
  - Dynamically toggle `ignoresMouseEvents = false` only while the cursor is inside an interactive control rect, and immediately restore `ignoresMouseEvents = true` when the cursor exits.

## 4. Coordinate Conversion (`Vision` Bottom-Left to `NSScreen` Top-Left / AppKit)
- `Vision` normalized bounding boxes (`CGRect` in `[0, 1] x [0, 1]`) use a **bottom-left** origin (`y = 0` at the bottom of the image, `y = 1` at the top).
- `NSScreen` / AppKit global window coordinates use a **bottom-left** origin relative to the primary display, whereas wire payloads / `CGDisplay` / `AXUIElement` use a **top-left** origin (`y` increases downward).
- Always convert per target `NSScreen.frame` (never hardcode primary display bounds or scale `1.0`):
  - **Vision normalized (`[0, 1]`, bottom-left) -> Top-left display coordinates (`y` down):**
    ```swift
    let topLeftX = screenFrame.minX + visionRect.minX * screenFrame.width
    let topLeftY = screenFrame.minY + (1.0 - visionRect.maxY) * screenFrame.height
    let width = visionRect.width * screenFrame.width
    let height = visionRect.height * screenFrame.height
    ```
  - **Top-left display coordinates -> AppKit `NSScreen` / `NSWindow` coordinates (`y` up):**
    ```swift
    let appKitY = primaryScreenMaxY - (topLeftY + height)
    ```
  - **Vision normalized (`[0, 1]`, bottom-left) -> Direct `NSView` / `NSScreen` local AppKit bounds (`y` up):**
    ```swift
    let localRect = CGRect(
        x: visionRect.minX * bounds.width,
        y: visionRect.minY * bounds.height,
        width: visionRect.width * bounds.width,
        height: visionRect.height * bounds.height
    )
    ```
- Account for `screen.backingScaleFactor` when converting between pixel buffers and point-based AppKit frames.
