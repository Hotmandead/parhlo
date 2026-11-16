import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CompanionCore

@Suite("CompanionCore Phase 3 Tests")
struct CaptureAndBridgeTests {
    // MARK: - Wire Protocol Models (schemas.py parity)

    @Test("Encodes and decodes UpstreamMessage variants matching schemas.py")
    func upstreamMessageRoundTrip() throws {
        let sessionMsg = UpstreamMessage.sessionControl(SessionControlMessage(action: .startSession))
        let sessionData = try JSONEncoder().encode(sessionMsg)
        let sessionJSON = try #require(JSONSerialization.jsonObject(with: sessionData) as? [String: Any])
        #expect(sessionJSON["type"] as? String == "session_control")
        #expect(sessionJSON["action"] as? String == "start_session")
        #expect(try JSONDecoder().decode(UpstreamMessage.self, from: sessionData) == sessionMsg)

        let ax = AXElementBounds(
            role: "AXButton",
            title: "Run",
            description: "Run build",
            value: nil,
            x: 100,
            y: 200,
            width: 80,
            height: 32
        )
        let screenMsg = UpstreamMessage.screenContext(
            ScreenContextMessage(
                screenWidth: 1512,
                screenHeight: 982,
                scaleFactor: 2.0,
                jpegB64: "ZmFrZQ==",
                axElements: [ax],
                frontmostBundleId: "com.apple.dt.Xcode"
            )
        )
        let screenData = try JSONEncoder().encode(screenMsg)
        let screenJSON = try #require(JSONSerialization.jsonObject(with: screenData) as? [String: Any])
        #expect(screenJSON["type"] as? String == "screen_context")
        #expect(screenJSON["screen_width"] as? Int == 1512)
        #expect(screenJSON["screen_height"] as? Int == 982)
        #expect(screenJSON["scale_factor"] as? Double == 2.0)
        #expect(screenJSON["jpeg_b64"] as? String == "ZmFrZQ==")
        #expect(screenJSON["frontmost_bundle_id"] as? String == "com.apple.dt.Xcode")
        #expect(try JSONDecoder().decode(UpstreamMessage.self, from: screenData) == screenMsg)

        let audioMsg = UpstreamMessage.audioUp(AudioUpMessage(pcmB64: "AAAA"))
        let audioData = try JSONEncoder().encode(audioMsg)
        let audioJSON = try #require(JSONSerialization.jsonObject(with: audioData) as? [String: Any])
        #expect(audioJSON["type"] as? String == "audio_up")
        #expect(audioJSON["pcm_b64"] as? String == "AAAA")
        #expect(try JSONDecoder().decode(UpstreamMessage.self, from: audioData) == audioMsg)
    }

    @Test("Decodes all DownstreamEvent discriminator variants matching schemas.py")
    func downstreamEventDecoding() throws {
        let drawJSON = """
        {
          "type": "draw_command",
          "command_id": "cmd-99",
          "action": "point_arrow",
          "from_point": {"x": 500, "y": 400},
          "to_point": {"x": 300, "y": 220},
          "label": "Click Export",
          "color": "#10B981"
        }
        """
        let drawEvent = try JSONDecoder().decode(DownstreamEvent.self, from: Data(drawJSON.utf8))
        guard case .drawCommand(let cmd) = drawEvent else {
            Issue.record("Expected drawCommand")
            return
        }
        #expect(cmd.commandId == "cmd-99")
        #expect(cmd.action == .pointArrow)
        #expect(cmd.toPoint == Point2D(x: 300, y: 220))

        let audioJSON = """
        {"type": "audio_down", "pcm_b64": "//8AAQ=="}
        """
        let audioEvent = try JSONDecoder().decode(DownstreamEvent.self, from: Data(audioJSON.utf8))
        #expect(audioEvent == .audioDown(AudioDownMessage(pcmB64: "//8AAQ==")))

        let bargeInJSON = """
        {"type": "barge_in", "reason": "manual"}
        """
        let bargeInEvent = try JSONDecoder().decode(DownstreamEvent.self, from: Data(bargeInJSON.utf8))
        #expect(bargeInEvent == .bargeIn(BargeInMessage(reason: .manual)))

        let hudJSON = """
        {"type": "hud_state", "state": "thinking", "transcript_snippet": "Checking sidebar"}
        """
        let hudEvent = try JSONDecoder().decode(DownstreamEvent.self, from: Data(hudJSON.utf8))
        #expect(hudEvent == .hudState(HudStateMessage(state: .thinking, transcriptSnippet: "Checking sidebar")))
    }

    // MARK: - PrivacyFilter

    @Test("PrivacyFilter enforces default and custom bundle-ID exclusions and updates HUD")
    @MainActor
    func privacyFilterExclusionsAndTransitions() {
        let store = OverlayStateStore()
        store.apply(HudStateMessage(state: .listening, transcriptSnippet: "Listening"))
        let filter = PrivacyFilter(overlayStore: store)

        // Default password managers
        #expect(filter.isExcluded(bundleIdentifier: "com.apple.keychainaccess"))
        #expect(filter.isExcluded(bundleIdentifier: "com.apple.Passwords"))
        #expect(filter.isExcluded(bundleIdentifier: "com.1password.1password"))
        #expect(filter.isExcluded(bundleIdentifier: "com.agilebits.onepassword7"))
        #expect(filter.isExcluded(bundleIdentifier: "com.bitwarden.desktop"))
        #expect(filter.isExcluded(bundleIdentifier: "com.dashlane.dashlanephonefinal"))
        // Case-insensitive match and non-excluded bundle IDs
        #expect(filter.isExcluded(bundleIdentifier: "COM.APPLE.PASSWORDS"))
        #expect(!filter.isExcluded(bundleIdentifier: "com.apple.Safari"))
        #expect(!filter.isExcluded(bundleIdentifier: nil))

        var events: [(Bool, String?)] = []
        filter.onPauseStateChanged = { paused, bundleID in
            events.append((paused, bundleID))
        }

        // Activating 1Password pauses capture and sets HUD to privacy_paused.
        filter.evaluateFrontmostApplication(bundleIdentifier: "com.1password.1password", appName: "1Password")
        #expect(filter.isPaused)
        #expect(store.hudState == .privacyPaused)
        #expect(store.transcriptSnippet == "Paused for 1Password")
        #expect(events.count == 1)
        #expect(events.first?.0 == true)

        // Returning to Xcode resumes capture and restores prior listening state.
        filter.evaluateFrontmostApplication(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")
        #expect(!filter.isPaused)
        #expect(store.hudState == .listening)
        #expect(events.count == 2)
        #expect(events.last?.0 == false)

        // Custom bundle-ID exclusion
        filter.addExcludedBundleID("com.example.BankingApp")
        filter.evaluateFrontmostApplication(bundleIdentifier: "com.example.BankingApp", appName: "BankingApp")
        #expect(filter.isPaused)
        #expect(store.hudState == .privacyPaused)

        filter.removeExcludedBundleID("com.example.BankingApp")
        #expect(!filter.isPaused)
        #expect(store.hudState == .listening)
    }

    // MARK: - VisionRedactor

    @Test("VisionRedactor detects sensitive text patterns and custom regexes")
    func visionRedactorPatternDetection() {
        let redactor = VisionRedactor(customPatterns: [#"INTERNAL-[A-Z0-9]{6}"#])

        #expect(redactor.containsSensitiveText("GEMINI_API_KEY=AIzaSyDummyKey1234567890abcdefg"))
        #expect(redactor.containsSensitiveText("sk-proj-abc1234567890xyzABC"))
        #expect(redactor.containsSensitiveText("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(redactor.containsSensitiveText("password: superSecretValue99"))
        #expect(redactor.containsSensitiveText("Card 4111-1111-1111-1111"))
        #expect(redactor.containsSensitiveText("SSN 123-45-6789"))
        #expect(redactor.containsSensitiveText("Token INTERNAL-AB12CD"))

        #expect(!redactor.containsSensitiveText("Click the Build button in Xcode"))
        #expect(!redactor.containsSensitiveText("Window width is 1512 px"))
    }

    @Test("VisionRedactor paints black masks over sensitive text in CGImage")
    func visionRedactorMasksSensitiveImageRegion() async throws {
        let width = 900
        let height = 360
        let syntheticImage = try #require(
            renderTextImage(
                width: width,
                height: height,
                topLine: "Safe label: Hello Parhlo",
                bottomLine: "sk-proj-1234567890abcdefghij"
            )
        )

        let redactor = VisionRedactor(recognitionLevel: .accurate, preferCPUOnly: true)
        let result = await redactor.redactWithDetails(image: syntheticImage)

        #expect(result.recognizedLineCount >= 1)
        #expect(result.redactedRegionCount >= 1)

        // Verify solid black mask pixels exist in the bottom band where the API key was rendered,
        // while the top band remains non-black (white background + dark non-redacted text).
        let bottomDarkPixels = countNearBlackPixels(
            in: result.image,
            rect: CGRect(x: 40, y: 30, width: 820, height: 120)
        )
        let topWhitePixels = countNearWhitePixels(
            in: result.image,
            rect: CGRect(x: 40, y: 210, width: 820, height: 110)
        )

        #expect(bottomDarkPixels > 4000)
        #expect(topWhitePixels > 50_000)
    }

    // MARK: - AXInspector & CaptureEngine Helpers

    @Test("AXInspector filters off-screen/zero-sized bounds and sanitizes sensitive values")
    func axInspectorFilteringAndSanitization() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(AXInspector.isVisibleFrame(CGRect(x: 100, y: 100, width: 200, height: 40), within: screen))
        #expect(!AXInspector.isVisibleFrame(CGRect(x: 100, y: 100, width: 0, height: 40), within: screen))
        #expect(!AXInspector.isVisibleFrame(CGRect(x: 2000, y: 100, width: 100, height: 40), within: screen))

        let redactor = VisionRedactor()
        #expect(AXInspector.sanitizeText("secret", role: "AXSecureTextField", isValueAttribute: true, redactor: redactor) == nil)
        #expect(AXInspector.sanitizeText("AIzaSyDummyKey1234567890abcdefg", role: "AXTextField", isValueAttribute: true, redactor: redactor) == "[REDACTED]")

        let longText = String(repeating: "a", count: 200)
        let truncated = AXInspector.sanitizeText(longText, maxLength: 40, redactor: redactor)
        #expect(truncated?.count == 40)
        #expect(truncated?.hasSuffix("…") == true)
    }

    @Test("CaptureEngine builds ScreenContextMessage with 0.65 JPEG encoding")
    func captureEngineBuildsScreenContextMessage() throws {
        let image = try #require(
            renderTextImage(width: 320, height: 180, topLine: "Parhlo", bottomLine: "Test Frame")
        )
        let message = try CaptureEngine.buildContextMessage(
            redactedImage: image,
            screenWidth: 1512,
            screenHeight: 982,
            scaleFactor: 2.0,
            axElements: [AXElementBounds(role: "AXWindow", title: "Editor", x: 0, y: 0, width: 1512, height: 982)],
            frontmostBundleId: "com.apple.dt.Xcode"
        )

        #expect(message.type == "screen_context")
        #expect(message.screenWidth == 1512)
        #expect(message.screenHeight == 982)
        #expect(message.scaleFactor == 2.0)
        #expect(message.axElements.count == 1)
        let decodedJPEG = try #require(Data(base64Encoded: message.jpegB64))
        // JPEG files start with SOI marker 0xFF 0xD8.
        #expect(decodedJPEG.prefix(2) == Data([0xFF, 0xD8]))
    }

    // MARK: - SidecarWebSocketClient & OverlayStateStore

    @Test("SidecarWebSocketClient dispatches draw_command, hud_state, barge_in, and audio_down")
    @MainActor
    func webSocketClientDispatchesEvents() throws {
        let store = OverlayStateStore()
        let client = SidecarWebSocketClient(overlayStore: store)

        let receivedAudio = LockedBuffer<AudioDownMessage>()
        let receivedBargeIn = LockedBuffer<BargeInMessage>()
        client.onAudioDown = { chunk in receivedAudio.append(chunk) }
        client.onBargeIn = { signal in receivedBargeIn.append(signal) }

        let drawPayload = """
        {
          "type": "draw_command",
          "command_id": "cmd-ws-1",
          "action": "highlight_region",
          "pixel_rect": {"x": 80, "y": 100, "width": 200, "height": 48},
          "label": "Submit",
          "color": "#3B82F6"
        }
        """
        try client.handleIncomingText(drawPayload)
        #expect(store.hudState == .drawing)
        #expect(store.highlights.count == 1)

        let audioPayload = """
        {"type": "audio_down", "pcm_b64": "AQID"}
        """
        try client.handleIncomingText(audioPayload)
        #expect(receivedAudio.snapshot() == [AudioDownMessage(pcmB64: "AQID")])

        let bargeInPayload = """
        {"type": "barge_in", "reason": "vad_interrupted"}
        """
        try client.handleIncomingText(bargeInPayload)
        #expect(!store.hasAnnotations)
        #expect(store.hudState == .listening)
        #expect(receivedBargeIn.snapshot() == [BargeInMessage(reason: .vadInterrupted)])

        let privacyHudPayload = """
        {"type": "hud_state", "state": "privacy_paused", "transcript_snippet": "Paused for Passwords"}
        """
        try client.handleIncomingText(privacyHudPayload)
        #expect(store.hudState == .privacyPaused)
        #expect(store.transcriptSnippet == "Paused for Passwords")
    }

    @Test("SidecarWebSocketClient computes capped exponential reconnect delays")
    func exponentialBackoffDelays() {
        #expect(SidecarWebSocketClient.reconnectDelay(attempt: 0, initialDelay: 0.5, maxDelay: 16.0) == 0.5)
        #expect(SidecarWebSocketClient.reconnectDelay(attempt: 1, initialDelay: 0.5, maxDelay: 16.0) == 1.0)
        #expect(SidecarWebSocketClient.reconnectDelay(attempt: 2, initialDelay: 0.5, maxDelay: 16.0) == 2.0)
        #expect(SidecarWebSocketClient.reconnectDelay(attempt: 10, initialDelay: 0.5, maxDelay: 16.0) == 16.0)
    }

    // MARK: - Image Helpers for Vision OCR Tests

    private func renderTextImage(
        width: Int,
        height: Int,
        topLine: String,
        bottomLine: String
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo" as CFString, 32, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black.cgColor,
        ]

        drawLine(topLine, at: CGPoint(x: 48, y: CGFloat(height) - 96), attributes: attrs, in: context)
        drawLine(bottomLine, at: CGPoint(x: 48, y: 72), attributes: attrs, in: context)

        return context.makeImage()
    }

    private func drawLine(
        _ text: String,
        at origin: CGPoint,
        attributes: [NSAttributedString.Key: Any],
        in context: CGContext
    ) {
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    private func countNearBlackPixels(in image: CGImage, rect: CGRect) -> Int {
        countPixels(in: image, rect: rect) { r, g, b in
            r < 12 && g < 12 && b < 12
        }
    }

    private func countNearWhitePixels(in image: CGImage, rect: CGRect) -> Int {
        countPixels(in: image, rect: rect) { r, g, b in
            r > 240 && g > 240 && b > 240
        }
    }

    private func countPixels(
        in image: CGImage,
        rect: CGRect,
        matching predicate: (UInt8, UInt8, UInt8) -> Bool
    ) -> Int {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Note: CGContext raw buffer row 0 corresponds to top of image (flipped relative to CGContext y=0 bottom).
        let minX = max(0, Int(rect.minX))
        let maxX = min(width, Int(rect.maxX))
        let minBufferY = max(0, height - Int(rect.maxY))
        let maxBufferY = min(height, height - Int(rect.minY))

        var matches = 0
        for y in minBufferY..<maxBufferY {
            for x in minX..<maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if predicate(buffer[offset], buffer[offset + 1], buffer[offset + 2]) {
                    matches += 1
                }
            }
        }
        return matches
    }
}

private final class LockedBuffer<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        items.append(element)
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
