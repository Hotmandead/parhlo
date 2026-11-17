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
# Edit .env and set GEMINI_API_KEY=your_key_here (from https://aistudio.google.com/apikey)

# Build and test the Dockerized Python sidecar
docker compose build
docker compose run --rm sidecar pytest -v

# Start the sidecar WebSocket server in the background (ws://127.0.0.1:8765)
docker compose up -d
```

> **Live Python Reloading:** `compose.yaml` bind-mounts `./agent-sidecar:/app/agent-sidecar` and runs `watchfiles` watching `/app/agent-sidecar/src`, so saving any `.py` file under `agent-sidecar/src/` automatically restarts the sidecar process inside the container. Only run `docker compose up -d --build` (or recreate `sidecar_venv` via `docker compose down -v && docker compose up -d --build`) when changing `Dockerfile` or `agent-sidecar/pyproject.toml` dependencies.

## 4. Native macOS App Commands

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

## 5. TCC Permissions & Code Signing Persistence

Parhlo requires four macOS Privacy & Security (TCC) permissions:
1. **Screen Recording** (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`)
2. **Accessibility** (`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`)
3. **Microphone** (`AVCaptureDevice.authorizationStatus(for: .audio)`)
4. **Speech Recognition** (`SFSpeechRecognizer.authorizationStatus()`)

Sign `com.parhlo.ScreenCompanionApp` in `Parhlo.xcodeproj` with a stable Apple Development / Personal Team certificate (`CODE_SIGN_STYLE = Automatic`) so rebuilds preserve TCC grants across runs. To reset stale TCC entries during debugging:
```bash
tccutil reset All com.parhlo.ScreenCompanionApp
```

## 6. Git Branch Workflow

- `main` (`origin/main`) — Stable release branch.
- `dev` (`origin/dev`) — Integration branch.
- `feat/macos-app` (`origin/feat/macos-app`) — Feature branch for `macos-app/` changes (branched from `dev`).
- `feat/agent-sidecar` (`origin/feat/agent-sidecar`) — Feature branch for `agent-sidecar/` & Docker changes (branched from `dev`).
