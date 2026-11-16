import CoreGraphics
import Foundation
import Testing
@testable import CompanionCore

@Suite("CompanionCore Phase 5 Native Intelligence Tests")
struct Phase5IntelligenceTests {
    @Test("ScreenContextMessage encodes and decodes Phase 5 detected_rects and document_context")
    func screenContextPhase5WireParity() throws {
        let rects = [
            DetectedRectBounds(x: 120, y: 240, width: 180, height: 42, confidence: 0.92)
        ]
        let doc = DocumentContext(
            title: "Architecture Spec",
            paragraphs: ["Parhlo captures screen context at <= 1 FPS."],
            tables: [DocumentTableSummary(rows: [["Module", "Language"], ["CompanionCore", "Swift 6"]])],
            truncated: false
        )
        let message = ScreenContextMessage(
            screenWidth: 1512,
            screenHeight: 982,
            scaleFactor: 2.0,
            jpegB64: "Zm9v",
            axElements: [],
            frontmostBundleId: "com.apple.Preview",
            detectedRects: rects,
            documentContext: doc
        )

        let data = try JSONEncoder().encode(message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["detected_rects"] != nil)
        #expect(json["document_context"] != nil)

        let decoded = try JSONDecoder().decode(ScreenContextMessage.self, from: data)
        #expect(decoded == message)
        #expect(decoded.detectedRects == rects)
        #expect(decoded.documentContext == doc)
    }

    @Test("AXInspector.isSparseTree identifies container-only or empty trees and rich control trees")
    func axSparseTreeDetection() {
        #expect(AXInspector.isSparseTree([]) == true)

        let containersOnly = [
            AXElementBounds(role: "AXWindow", title: "Window", x: 0, y: 0, width: 800, height: 600),
            AXElementBounds(role: "AXGroup", title: nil, x: 10, y: 10, width: 400, height: 300)
        ]
        #expect(AXInspector.isSparseTree(containersOnly) == true)

        let richControls = [
            AXElementBounds(role: "AXButton", title: "Run", x: 10, y: 10, width: 60, height: 24),
            AXElementBounds(role: "AXButton", title: "Stop", x: 80, y: 10, width: 60, height: 24),
            AXElementBounds(role: "AXTextField", title: "Search", x: 150, y: 10, width: 200, height: 24),
            AXElementBounds(role: "AXCheckBox", title: "Filter", x: 360, y: 10, width: 80, height: 24)
        ]
        #expect(AXInspector.isSparseTree(richControls) == false)
    }

    @Test("VisionRedactor.redactSensitiveText masks inline secrets and SemanticPIIClassifier flags contextual PII")
    func semanticPrivacyAndInlineRedaction() async throws {
        let redactor = VisionRedactor()
        let raw = "Export key sk-proj-1234567890abcdefghijklmnop for deployment."
        let sanitized = redactor.redactSensitiveText(raw)
        #expect(!sanitized.contains("sk-proj-1234567890"))
        #expect(sanitized.contains("[REDACTED]"))

        let classifier = HeuristicSemanticPIIClassifier()
        let lines = [
            "Welcome to Parhlo Settings",
            "My bank card PIN is 4829",
            "Click Run to build the workspace"
        ]
        let flagged = try await classifier.classifySensitiveLineIndices(lines)
        #expect(flagged.contains(1))
        #expect(!flagged.contains(0))
        #expect(!flagged.contains(2))
    }

    @Test("OfflineAssistantEngine and AppCoordinator.runOfflineFallback answer from redacted context")
    @MainActor
    func offlineAssistantFallbackBehavior() async throws {
        let engine = OfflineAssistantEngine()
        let context = OfflineScreenContext(
            sanitizedOCRText: "Build succeeded with 0 errors\nTarget: Parhlo.app",
            axElements: [
                AXElementBounds(role: "AXButton", title: "Run Build", x: 20, y: 40, width: 100, height: 30)
            ],
            frontmostBundleID: "com.apple.dt.Xcode",
            frontmostAppName: "Xcode"
        )
        let answer = try await engine.answer(prompt: "What is on my screen?", context: context)
        #expect(!answer.isEmpty)

        let store = OverlayStateStore()
        let coordinator = AppCoordinator(
            sidecarURL: URL(string: "ws://127.0.0.1:1")!,
            overlayStore: store,
            offlineEngine: engine
        )
        coordinator.backendMode = .offlineOnly
        coordinator.setOutputMuted(true)
        await coordinator.runOfflineFallback(for: "What app is open?")
        #expect(store.messages.last?.isUser == false)
        #expect(store.messages.last?.text.isEmpty == false)
        coordinator.webSocketClient.disconnect()
    }
}
