import AppKit
import Testing
@testable import CompanionCore

@Suite("Notch Hover & Drawer Geometry Tests")
struct NotchHoverTests {
    @Test("isPointInTopTriggerZone detects top-center notch strip and rejects corners or bottom")
    func topTriggerZoneBounds() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Inside top-center trigger strip (midX = 720, maxY = 900, y in [862, 900], x in [570, 870])
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 720, y: 895), screenFrame: screenFrame) == true)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 570, y: 862), screenFrame: screenFrame) == true)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 870, y: 900), screenFrame: screenFrame) == true)

        // Outside: top-left, top-right, bottom, below strip, above screen
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 40, y: 895), screenFrame: screenFrame) == false)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 1400, y: 895), screenFrame: screenFrame) == false)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 569, y: 880), screenFrame: screenFrame) == false)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 720, y: 861), screenFrame: screenFrame) == false)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 720, y: 100), screenFrame: screenFrame) == false)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 720, y: 901), screenFrame: screenFrame) == false)

        // Non-zero origin display
        let secondaryScreen = NSRect(x: 1440, y: 100, width: 1728, height: 1117)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 2304, y: 1200), screenFrame: secondaryScreen) == true)
        #expect(NotchPanelWindowController.isPointInTopTriggerZone(NSPoint(x: 1500, y: 1200), screenFrame: secondaryScreen) == false)
    }

    @Test("isPointInsideExpandedDrawer includes 16pt grace margin around panelFrame")
    func expandedDrawerBounds() {
        let panelFrame = NSRect(x: 450, y: 456, width: 540, height: 440)

        // Strictly inside drawer
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 720, y: 680), panelFrame: panelFrame) == true)
        // Inside 16pt grace margin outside drawer edges
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 440, y: 680), panelFrame: panelFrame) == true)
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 1000, y: 680), panelFrame: panelFrame) == true)
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 720, y: 445), panelFrame: panelFrame) == true)
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 720, y: 905), panelFrame: panelFrame) == true)

        // Outside 16pt grace margin
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 430, y: 680), panelFrame: panelFrame) == false)
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 1010, y: 680), panelFrame: panelFrame) == false)
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 720, y: 430), panelFrame: panelFrame) == false)
        #expect(NotchPanelWindowController.isPointInsideExpandedDrawer(NSPoint(x: 720, y: 920), panelFrame: panelFrame) == false)
    }

    @Test("NotchPanelWindowController supports non-activating hover expansion and clean monitor teardown")
    @MainActor
    func hoverExpandAndTeardown() {
        let coordinator = AppCoordinator()
        let notch = NotchPanelWindowController(coordinator: coordinator, onOpenSettings: {})
        defer { notch.stopHoverMonitoring() }

        #expect(notch.isExpanded == false)
        #expect(notch.panel.canBecomeKey == false)

        notch.setExpanded(true, activateApp: false)
        #expect(notch.isExpanded == true)
        #expect(notch.panel.canBecomeKey == true)

        notch.setExpanded(false, activateApp: false)
        #expect(notch.isExpanded == false)
        #expect(notch.panel.canBecomeKey == false)
    }
}
