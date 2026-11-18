---
name: screencapture-pipeline
description: Rules for implementing the ScreenCaptureKit SCStream pipeline, Vision feature-print frame diffing, and thread-safe CVPixelBuffer handling in Parhlo.
---

# ScreenCaptureKit & Vision Pipeline Rules

## 1. SCStreamConfiguration & Content Filtering
- **Frame Rate Cap:** Configure `SCStreamConfiguration.minimumFrameInterval` to enforce a strict **2–5 FPS cap** (e.g., `CMTime(value: 1, timescale: 2)` to `CMTime(value: 1, timescale: 5)`). Never run uncapped 60 FPS capture for AI context streaming.
- **No Deprecated APIs:** Never use `CGWindowListCreateImage` or `CGDisplayCreateImage`. Always use `ScreenCaptureKit` (`SCStream`, `SCShareableContent`).
- **Exclude Self to Prevent Feedback Loops:**
  - Query `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`.
  - Filter out all `SCRunningApplication` entries matching the host bundle identifier (`com.parhlo.ScreenCompanionApp` / `Bundle.main.bundleIdentifier`).
  - Also exclude Parhlo's own `SCWindow` instances via `SCContentFilter(display:excludingApplications:exceptingWindows:)` so overlay HUDs never appear in captured frames.
- **Pixel Format & Queue Depth:** Use `kCVPixelFormatType_32BGRA` and keep `SCStreamConfiguration.queueDepth` small (e.g., `3`–`5`) to avoid backpressure memory spikes.

## 2. Vision Feature-Print Frame Diffing
- Run `VNGenerateImageFeaturePrintRequest` on a dedicated background `DispatchQueue` or Swift `actor` (never on `@MainActor`).
- Before encoding or transmitting any frame over the WebSocket/network:
  1. Compute the `VNFeaturePrintObservation` for the candidate `CVPixelBuffer`.
  2. Compare against the previous transmitted frame's observation using `computeDistance(_:to:)`.
  3. Skip transmission if the feature-print distance is below the configured change threshold (unless an explicit on-demand user trigger forces a capture).
- Run on-device `VisionRedactor` / `PrivacyFilter` checks before any frame leaves the device.

## 3. Thread-Safe CVPixelBuffer Release
- Process `CMSampleBuffer` / `CVPixelBuffer` inside the `SCStreamOutput` callback (`stream(_:didOutputSampleBuffer:of:)`) on the dedicated capture `DispatchQueue`.
- Validate frame status (`SCFrameStatus.complete`) via `SCStreamFrameInfo.status` before accessing `CMSampleBufferGetImageBuffer`.
- **Never retain `CMSampleBuffer` or `CVPixelBuffer` across async/await suspension points** unless explicitly copied into an owned `CGImage` / `Data` / `CIImage` buffer first; holding raw `SCStream` pool buffers starves ScreenCaptureKit and stalls the stream.
- Whenever reading raw bytes from a `CVPixelBuffer`:
  ```swift
  CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
  ```
- Under Swift 6 strict concurrency, convert or serialize pixel data into `Sendable` types (`Data`, `CGImage`, or immutable value structs) before crossing actor boundaries.
