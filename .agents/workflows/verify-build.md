---
description: Verify Parhlo macOS app privacy descriptions, network entitlements, clean Xcode build, and unit tests
---

# Verify Build (`/verify-build`)

Run these steps from the repository root (`/Users/arsalanwahidasghar/Documents/Developer/parhlo`) to validate the macOS build configuration, entitlements, compilation, and unit tests.

## 1. Check `Info.plist` Usage Descriptions & Entitlements
Verify `NSScreenCaptureUsageDescription` is present in `macos-app/Parhlo/Info.plist` and inspect `macos-app/Parhlo/Parhlo.entitlements` for network/sandbox configuration:

```bash
/usr/libexec/PlistBuddy -c "Print :NSScreenCaptureUsageDescription" macos-app/Parhlo/Info.plist
plutil -lint macos-app/Parhlo/Info.plist macos-app/Parhlo/Parhlo.entitlements
```

If `com.apple.security.app-sandbox` is `true` in `macos-app/Parhlo/Parhlo.entitlements`, confirm `com.apple.security.network.client` is also `true` so the local WebSocket client (`ws://127.0.0.1:8765`) and `google-genai` proxy calls are permitted:

```bash
/usr/libexec/PlistBuddy -c "Print" macos-app/Parhlo/Parhlo.entitlements
```

## 2. Clean `xcodebuild` Compile (`Parhlo` Scheme)
Ensure Xcode's developer directory is active and run a clean build for Apple Silicon (`arm64`):

```bash
xcodebuild clean build -workspace Parhlo.xcworkspace -scheme Parhlo -configuration Debug -destination 'platform=macOS,arch=arm64'
```

## 3. Execute Unit Tests
Run the `Parhlo` workspace test suite and `CompanionCore` SwiftPM tests:

```bash
xcodebuild test -workspace Parhlo.xcworkspace -scheme Parhlo -configuration Debug -destination 'platform=macOS,arch=arm64'
```

For fast Swift package iteration:

```bash
cd macos-app/Packages/CompanionCore && swift test
```
