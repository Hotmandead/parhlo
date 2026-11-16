# macOS App Rules (Swift 6 / AppKit / SwiftUI)

## Environment & Build Tools
- `macos-app/` runs natively on Apple Silicon (`arm64-apple-macosx`, `.macOS(.v14)`+) and must **not** be containerized—`ScreenCaptureKit`, `AXUIElement`, `Vision`, `NSWindow`, and `AVAudioEngine` require native WindowServer, TCC, and CoreAudio access.
- Use Swift Package Manager (`Package.swift`) as the modular source of truth (`CompanionCore`, `ScreenCompanionApp`, `CompanionCoreTests`), wrapped by `Parhlo.xcodeproj` for `.app` signing, `Info.plist` TCC descriptions, and entitlements.

## Swift 6 Concurrency & Architecture
- Compile cleanly under **Swift 6 strict concurrency**.
- Isolate all `NSWindow`, `NSStatusItem`, `CAShapeLayer`, and SwiftUI observable state to `@MainActor`.
- Keep synchronous C-API calls (`AXUIElementCopyAttributeValue`, `Vision` OCR requests) off `@MainActor` (use dedicated background actors or `Task.detached`).
- Keep `CompanionCore` DTOs (`PixelRect`, `Point2D`, `DrawCommand`, `HudState`, etc.) `Sendable` and `Codable`, matching `../agent-sidecar/src/sidecar/schemas.py`.
- Never force-unwrap (`!`) optionals in runtime paths; use `guard` / explicit error handling.

## Overlay, Capture & Audio Invariants
- **Prevent Feedback Loops:** Set `window.sharingType = .none` on overlay windows **and** explicitly exclude Parhlo's own bundle ID (`SCContentFilter(display:excludingApplications:exceptingWindows:)`) in `ScreenCaptureKit`—modern macOS (15+) can ignore `sharingType = .none` alone.
- **Click-Through Overlay:** Overlay windows must keep `ignoresMouseEvents = true` and `canBecomeKey == false` / `canBecomeMain == false` so clicks pass directly to underlying apps.
- **Coordinate Conversion:** Wire payloads use top-left screen origin (`y` down); flip to AppKit bottom-left coordinates accurately per screen frame before rendering.
- **Voice & Hotkey:** Enable `AVAudioEngine` voice processing echo cancellation (`setVoiceProcessingEnabled(true)`), flush `AVAudioPlayerNode` immediately on `barge_in`, and bind `Control+Option` (`⌃⌥`) as the voice trigger alongside the menu bar item.

## Quality Gate
Before finishing any `macos-app/` change, run:
```bash
cd macos-app && swift build && swift test
```
