---
name: macos-tcc-signing
description: >-
  Use this skill when configuring macOS TCC permissions (Screen Recording,
  Accessibility, Microphone), Info.plist usage descriptions, entitlements, code
  signing, or debugging permission prompts in Parhlo.
---

# macOS TCC Permissions & Signing Runbook

macOS tracks TCC grants by bundle identifier and code signature. Bare SwiftPM executables lack a stable `.app` bundle identity, so Parhlo wraps `ScreenCompanionApp` in `macos-app/Parhlo.xcodeproj`.

## Required `Info.plist` Keys

- `NSMicrophoneUsageDescription` — explains 16 kHz bidirectional voice capture.
- `NSScreenCaptureUsageDescription` — explains on-demand `ScreenCaptureKit` frame capture.
- `NSAppleEventsUsageDescription` (only if AppleEvents are used; `AXUIElement` uses Accessibility TCC).

## Required Runtime Permission Checks

1. **Screen Recording:** `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
   - Settings URL: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
2. **Accessibility (`AXUIElement`):** `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`
   - Settings URL: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
3. **Microphone:** `AVCaptureDevice.authorizationStatus(for: .audio)` / `AVCaptureDevice.requestAccess(for: .audio)`
   - Settings URL: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`

## Entitlements Checklist

- Keep App Sandbox **disabled** (`com.apple.security.app-sandbox = false`) so `AXUIElement` can inspect frontmost third-party applications and `CGEventTap` / global monitors work reliably.
- Include `com.apple.security.device.audio-input` if Hardened Runtime is enabled.

## Resetting Stale TCC Grants During Development

If macOS stops prompting after a bundle ID or signing change, reset grants for Parhlo's bundle identifier:

```bash
tccutil reset ScreenCapture <bundle-id>
tccutil reset Accessibility <bundle-id>
tccutil reset Microphone <bundle-id>
```
