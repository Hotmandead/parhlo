import AppKit
import Foundation
import Testing
@testable import CompanionCore

@Suite("CompanionCore Phase 2 Tests")
struct OverlayAndModelsTests {
    @Test("Decodes DrawCommandMessage matching schemas.py snake_case payload")
    func decodesDrawCommand() throws {
        let json = """
        {
          "type": "draw_command",
          "command_id": "cmd-42",
          "action": "highlight_region",
          "pixel_rect": {"x": 120, "y": 80, "width": 240, "height": 48},
          "label": "Filter Input",
          "color": "#3B82F6",
          "style": "pulse",
          "matched_ax_role": "AXTextField",
          "matched_ax_title": "Filter"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(DrawCommandMessage.self, from: data)

        #expect(decoded.commandId == "cmd-42")
        #expect(decoded.action == .highlightRegion)
        #expect(decoded.pixelRect == PixelRect(x: 120, y: 80, width: 240, height: 48))
        #expect(decoded.label == "Filter Input")
        #expect(decoded.style == "pulse")
        #expect(decoded.matchedAxRole == "AXTextField")
        #expect(decoded.matchedAxTitle == "Filter")
    }

    @Test("Decodes HudStateMessage matching schemas.py payload")
    func decodesHudState() throws {
        let json = """
        {
          "type": "hud_state",
          "state": "privacy_paused",
          "transcript_snippet": "Paused for 1Password"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(HudStateMessage.self, from: data)

        #expect(decoded.state == .privacyPaused)
        #expect(decoded.transcriptSnippet == "Paused for 1Password")
    }

    @Test("Converts top-left pixel coordinates to AppKit bottom-left coordinates")
    func coordinateFlipping() {
        let screenSize = CGSize(width: 1512, height: 982)
        let rect = PixelRect(x: 100, y: 50, width: 200, height: 40)
        let localRect = CoordinateConverter.toAppKitLocalRect(rect, in: screenSize)

        #expect(localRect.origin.x == 100.0)
        #expect(localRect.origin.y == 892.0)
        #expect(localRect.size.width == 200.0)
        #expect(localRect.size.height == 40.0)

        let pt = CoordinateConverter.toAppKitLocalPoint(Point2D(x: 300, y: 120), in: screenSize)
        #expect(pt.x == 300.0)
        #expect(pt.y == 862.0)
    }

    @Test("OverlayStateStore routes highlight, arrow, callout, and clear_annotations")
    @MainActor
    func stateStoreTransitions() {
        let store = OverlayStateStore()
        #expect(store.hudState == .idle)
        #expect(!store.hasAnnotations)

        store.loadDemoAnnotations(for: CGSize(width: 1512, height: 982))
        #expect(store.hudState == .drawing)
        #expect(store.highlights.count == 1)
        #expect(store.arrows.count == 1)
        #expect(store.callouts.count == 1)

        store.apply(DrawCommandMessage(commandId: "clear-1", action: .clearAnnotations))
        #expect(!store.hasAnnotations)
        #expect(store.hudState == .idle)
    }

    @Test("OverlayWindowController configures non-activating click-through sharingType.none window")
    @MainActor
    func overlayWindowInvariants() {
        let store = OverlayStateStore()
        let controller = OverlayWindowController(store: store, screen: nil)
        let window = controller.window

        #expect(window.sharingType == .none)
        #expect(window.ignoresMouseEvents == true)
        #expect(window.isOpaque == false)
        #expect(window.level == .statusBar)
        #expect(window.canBecomeKey == false)
        #expect(window.canBecomeMain == false)
    }
}
