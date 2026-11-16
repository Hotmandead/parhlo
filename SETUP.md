# Parhlo Local Setup & CLI Commands

## 1. Configure Full Xcode Developer Directory

Point `xcode-select` to your full Xcode installation (`/Applications/Xcode.app/Contents/Developer`) so `xcodebuild`, `xcrun`, and Swift CLI builds use the complete macOS SDK (`MacOSX27.2.sdk`):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 2. Verify Xcode & Swift Tooling

```bash
# Expected: /Applications/Xcode.app/Contents/Developer
xcode-select -p

# Expected: Xcode 27.2 / Build version 27B52
xcodebuild -version

# Expected: exit code 0
xcodebuild -checkFirstLaunchStatus

# Expected: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk
xcrun --show-sdk-path --sdk macosx

# Confirm Swift toolchain
swift --version
```

---

## 3. Sidecar & Environment Commands

```bash
# Configure environment variables (skip if .env already exists)
cp .env.example .env

# Build and test the Dockerized Python sidecar
docker compose build
docker compose run --rm sidecar pytest -v

# Start the sidecar WebSocket server (ws://127.0.0.1:8765)
docker compose up
```

## 4. Native macOS App Commands (After Phase 2–4 Scaffolding)

```bash
cd macos-app/Packages/CompanionCore
swift build
swift test
```

Or build & test the full `.app` bundle via the root Xcode workspace:
```bash
xcodebuild -workspace Parhlo.xcworkspace -scheme Parhlo -configuration Debug build
xcodebuild -workspace Parhlo.xcworkspace -scheme Parhlo -configuration Debug test
```
