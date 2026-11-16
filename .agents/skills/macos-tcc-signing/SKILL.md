---
name: macos-tcc-signing
description: >-
  Use this skill when configuring macOS TCC permissions (Screen Recording,
  Accessibility, Microphone), Info.plist usage descriptions, entitlements, code
  signing, or debugging permission prompts in Parhlo.
---

# macOS TCC Permissions & Signing Runbook

macOS tracks TCC grants by bundle identifier and code signature. Bare SwiftPM executables lack a stable `.app` bundle identity, so the `Parhlo` app target in `macos-app/Parhlo.xcodeproj` (`macos-app/Parhlo/`) links `Packages/CompanionCore` and embeds `Info.plist` and `Parhlo.entitlements`.

## Required `Info.plist` Keys

- `NSMicrophoneUsageDescription` — explains 16 kHz bidirectional voice capture.
- `NSSpeechRecognitionUsageDescription` — explains on-device `SFSpeechRecognizer` voice-to-text into the `Ask Parhlo…` input bar.
- `NSScreenCaptureUsageDescription` — explains on-demand `ScreenCaptureKit` frame capture.
- `NSAppleEventsUsageDescription` (only if AppleEvents are used; `AXUIElement` uses Accessibility TCC).

## Permission Persistence Across Rebuilds (Critical!)

If `Parhlo.app` is **ad-hoc signed** (`CODE_SIGN_IDENTITY="-"` or `Signature=adhoc` when `security find-identity -v -p codesigning` shows `0 valid identities found`), macOS binds TCC grants to the binary's SHA-256 `cdhash`. Every rebuild changes the `cdhash`, forcing macOS to re-prompt for Screen Recording, Accessibility, Microphone, and Speech Recognition.

To persist TCC grants across rebuilds:
1. Either sign in with an Apple ID in **Xcode → Settings → Accounts** and select your **Personal Team** under **Signing & Capabilities** (`CODE_SIGN_STYLE = Automatic`), **or** create a local trusted **Code Signing** certificate in **Keychain Access → Certificate Assistant → Create a Certificate…** (e.g., `Parhlo Local Dev`, Identity Type: Self Signed Root, Certificate Type: Code Signing) and sign `Parhlo.xcodeproj` with it.
2. Reset any stale ad-hoc TCC entries once:
   ```bash
   tccutil reset All com.parhlo.ScreenCompanionApp
   ```

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
