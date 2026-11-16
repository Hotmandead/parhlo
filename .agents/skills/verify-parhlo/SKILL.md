---
name: verify-parhlo
description: >-
  Use this skill when verifying changes across the Parhlo Python sidecar, the
  native Swift macOS app, or the local Xcode toolchain before reporting work as
  complete.
---

# Verify Parhlo

Run the checks matching the components modified.

## 1. Python Sidecar (Docker)

Run unit tests inside the pinned container (never on host Python):

```bash
docker compose build
docker compose run --rm sidecar pytest -v
```

Expected: all tests in `agent-sidecar/tests/` pass with exit code `0`.

## 2. Native macOS App (Swift Package Manager & Xcode)

Ensure `xcode-select -p` points to `/Applications/Xcode.app/Contents/Developer`, then build and test:

```bash
cd macos-app
swift build
swift test
```

If verifying the `.app` bundle via Xcode CLI:

```bash
xcodebuild -project macos-app/Parhlo.xcodeproj -scheme Parhlo -configuration Debug build
```

## 3. End-to-End WebSocket Loopback Check

1. Start the sidecar: `docker compose up -d sidecar`
2. Verify `ws://127.0.0.1:8765` accepts a WebSocket handshake and dispatches `session_control` -> `screen_context` -> `draw_command` / `barge_in`.
3. Stop background container when finished if not actively developing: `docker compose down`
