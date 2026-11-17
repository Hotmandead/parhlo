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

    @Test("CoordinateConverter converts global Quartz rects to display-local rects and clamps points")
    func displayLocalCoordinateHelpers() {
        let displayBounds = CGRect(x: 1728, y: 120, width: 1440, height: 900)
        let globalRect = CGRect(x: 1928, y: 270, width: 200, height: 48)
        let local = CoordinateConverter.toDisplayLocalRect(globalRect, displayBounds: displayBounds)
        #expect(local == CGRect(x: 200, y: 150, width: 200, height: 48))

        let clamped = CoordinateConverter.clampedPoint(
            CGPoint(x: -30, y: 1200),
            in: CGSize(width: 1440, height: 900),
            inset: 12
        )
        #expect(clamped == CGPoint(x: 12, y: 888))
    }

    @Test("VectorAnnotationNSView synthesizes arrow start when fromPoint is nil, supports spotlight pulse, renders labels, and rebuilds updated commandId")
    @MainActor
    func vectorAnnotationRenderingAndUpdates() {
        let canvasSize = CGSize(width: 1440, height: 900)
        let synthesized = VectorAnnotationNSView.resolvedArrowStartPoint(
            from: nil,
            to: Point2D(x: 500, y: 400),
            canvasSize: canvasSize
        )
        #expect(synthesized == Point2D(x: 460, y: 360))

        let cornerSynthesized = VectorAnnotationNSView.resolvedArrowStartPoint(
            from: nil,
            to: Point2D(x: 10, y: 10),
            canvasSize: canvasSize
        )
        #expect(cornerSynthesized == Point2D(x: 50, y: 50))
        #expect(cornerSynthesized != Point2D(x: 10, y: 10))

        #expect(VectorAnnotationNSView.shouldShowPulseRing(style: "pulse") == true)
        #expect(VectorAnnotationNSView.shouldShowPulseRing(style: "spotlight") == true)
        #expect(VectorAnnotationNSView.shouldShowPulseRing(style: " Spotlight ") == true)
        #expect(VectorAnnotationNSView.shouldShowPulseRing(style: "solid") == false)

        let view = VectorAnnotationNSView(frame: NSRect(origin: .zero, size: canvasSize))
        let highlight1 = DrawCommandMessage(
            commandId: "hl-1",
            action: .highlightRegion,
            pixelRect: PixelRect(x: 100, y: 120, width: 200, height: 48),
            label: "Run Button",
            color: "#3B82F6",
            style: "spotlight"
        )
        let arrowNoFrom = DrawCommandMessage(
            commandId: "arr-1",
            action: .pointArrow,
            fromPoint: nil,
            toPoint: Point2D(x: 600, y: 300),
            label: "Click here",
            color: "#10B981"
        )

        view.update(highlights: [highlight1], arrows: [arrowNoFrom])

        let initialHighlightLayer = view.annotationLayers["hl-1"]
        let initialArrowLayer = view.annotationLayers["arr-1"]
        #expect(initialHighlightLayer != nil)
        #expect(initialArrowLayer != nil)
        // Highlight with "spotlight" + label creates pulse layer + box layer + label pill layer.
        #expect((initialHighlightLayer?.sublayers?.count ?? 0) == 3)
        // Arrow without explicit fromPoint still renders shaft + head + label pill layer.
        #expect((initialArrowLayer?.sublayers?.count ?? 0) == 3)

        // Updating the same commandId with modified pixelRect must rebuild the layer instead of skipping.
        let highlight1Updated = DrawCommandMessage(
            commandId: "hl-1",
            action: .highlightRegion,
            pixelRect: PixelRect(x: 320, y: 240, width: 260, height: 56),
            label: "Run Button Updated",
            color: "#EF4444",
            style: "pulse"
        )
        view.update(highlights: [highlight1Updated], arrows: [arrowNoFrom])

        let rebuiltHighlightLayer = view.annotationLayers["hl-1"]
        let unchangedArrowLayer = view.annotationLayers["arr-1"]
        #expect(rebuiltHighlightLayer != nil)
        #expect(rebuiltHighlightLayer !== initialHighlightLayer)
        #expect(unchangedArrowLayer === initialArrowLayer)
    }
}
