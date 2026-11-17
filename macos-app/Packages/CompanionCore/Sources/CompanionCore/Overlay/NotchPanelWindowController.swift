import AppKit
import SwiftUI

/// Interactive top-center `NSPanel` hosting the Notch Pill and expandable Assistant Drawer.
@MainActor
public final class NotchPanel: NSPanel {
    public var allowKeyFocus: Bool = false
    public override var canBecomeKey: Bool { allowKeyFocus }
    public override var canBecomeMain: Bool { false }
}

private struct EventMonitorBox: @unchecked Sendable {
    let token: Any
}

/// Container view providing `NSTrackingArea` hover callbacks alongside SwiftUI subviews.
@MainActor
private final class NotchHoverTrackingView: NSView {
    var onHoverEvent: ((NSPoint) -> Void)?
    private var activeTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let activeTrackingArea {
            removeTrackingArea(activeTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        activeTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverEvent?(NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHoverEvent?(NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverEvent?(NSEvent.mouseLocation)
    }
}

/// Manages the interactive camera-notch pill and expandable dark Assistant Drawer independently from the click-through overlay.
@MainActor
public final class NotchPanelWindowController {
    public let panel: NotchPanel
    public private(set) var isExpanded: Bool = false

    private let coordinator: AppCoordinator
    private let onOpenSettings: () -> Void
    private var hostingController: NSHostingController<NotchAssistantView>?
    private var trackingContainerView: NotchHoverTrackingView?
    private var activeScreen: NSScreen?
    nonisolated(unsafe) private var screenTask: Task<Void, Never>?
    nonisolated(unsafe) private var hoverCollapseTask: Task<Void, Never>?
    nonisolated(unsafe) private var globalMouseMonitor: EventMonitorBox?
    nonisolated(unsafe) private var localMouseMonitor: EventMonitorBox?
    nonisolated(unsafe) private var localMouseDownMonitor: EventMonitorBox?
    private var openedViaHover: Bool = false

    private static let collapsedSize = CGSize(width: 220, height: 34)
    private static let expandedSize = CGSize(width: 540, height: 440)

    public init(coordinator: AppCoordinator, onOpenSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onOpenSettings = onOpenSettings

        let initialFrame = Self.frame(for: Self.collapsedSize, on: NSScreen.main)
        let notchPanel = NotchPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.level = .statusBar
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        notchPanel.sharingType = .none
        notchPanel.hidesOnDeactivate = false

        self.panel = notchPanel
        refreshContentView()
        observeScreenChanges()
        startHoverMonitoring()
    }

    deinit {
        screenTask?.cancel()
        hoverCollapseTask?.cancel()
        let monitors = [globalMouseMonitor, localMouseMonitor, localMouseDownMonitor].compactMap { $0 }
        if !monitors.isEmpty {
            Task { @MainActor in
                for monitor in monitors {
                    NSEvent.removeMonitor(monitor.token)
                }
            }
        }
    }

    /// Returns `true` when `point` (in AppKit screen coordinates) is inside the top-center notch hover trigger strip.
    nonisolated public static func isPointInTopTriggerZone(_ point: NSPoint, screenFrame: NSRect) -> Bool {
        point.y >= screenFrame.maxY - 38
            && point.y <= screenFrame.maxY
            && abs(point.x - screenFrame.midX) <= 150
    }

    /// Returns the first screen frame from `screenFrames` whose top-center notch trigger strip contains `point`.
    nonisolated public static func matchingTriggerScreenFrame(
        for point: NSPoint,
        in screenFrames: [NSRect]
    ) -> NSRect? {
        screenFrames.first { isPointInTopTriggerZone(point, screenFrame: $0) }
    }

    /// Returns `true` when `point` is inside the expanded drawer bounds with a 16pt grace margin.
    nonisolated public static func isPointInsideExpandedDrawer(_ point: NSPoint, panelFrame: NSRect) -> Bool {
        panelFrame.insetBy(dx: -16, dy: -16).contains(point)
    }

    public func showPill() {
        updatePanelFrame(expanded: isExpanded)
        panel.orderFrontRegardless()
        startHoverMonitoring()
    }

    public func toggleExpanded() {
        setExpanded(!isExpanded, activateApp: true)
    }

    public func setExpanded(_ expanded: Bool) {
        setExpanded(expanded, activateApp: true)
    }

    public func setExpanded(_ expanded: Bool, activateApp: Bool) {
        setExpanded(expanded, activateApp: activateApp, on: activeScreen ?? panel.screen ?? NSScreen.main)
    }

    private func setExpanded(_ expanded: Bool, activateApp: Bool, on screen: NSScreen?) {
        if let screen {
            activeScreen = screen
        }
        isExpanded = expanded
        panel.allowKeyFocus = expanded
        if !expanded || activateApp {
            hoverCollapseTask?.cancel()
            hoverCollapseTask = nil
            openedViaHover = false
        }
        refreshContentView()
        updatePanelFrame(expanded: expanded, on: screen)
        if expanded {
            if activateApp {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                panel.orderFrontRegardless()
            }
        } else {
            panel.resignKey()
            panel.orderFrontRegardless()
        }
    }

    /// Minimizes the drawer back to the notch pill when opening Settings.
    internal func handleOpenSettingsFromDrawer() {
        setExpanded(false, activateApp: false)
        onOpenSettings()
    }

    /// Pins a hover-opened drawer open and gives it key focus so keyboard input works seamlessly.
    public func pinAndActivateForInteraction() {
        guard isExpanded else { return }
        openedViaHover = false
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil
        panel.allowKeyFocus = true
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Installs global + local mouse monitors for hover-to-expand and click-to-focus.
    public func startHoverMonitoring() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil, localMouseDownMonitor == nil else {
            return
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseLocation(NSEvent.mouseLocation)
            }
        }) {
            globalMouseMonitor = EventMonitorBox(token: global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleMouseLocation(NSEvent.mouseLocation)
            }
            return event
        }) {
            localMouseMonitor = EventMonitorBox(token: local)
        }

        if let mouseDown = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let windowNumber = event.windowNumber
            Task { @MainActor [weak self] in
                guard let self, windowNumber == self.panel.windowNumber else { return }
                self.pinAndActivateForInteraction()
            }
            return event
        }) {
            localMouseDownMonitor = EventMonitorBox(token: mouseDown)
        }
    }

    /// Removes active mouse event monitors and cancels pending hover-collapse timers.
    public func stopHoverMonitoring() {
        hoverCollapseTask?.cancel()
        hoverCollapseTask = nil

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor.token)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor.token)
            self.localMouseMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor.token)
            self.localMouseDownMonitor = nil
        }
    }

    /// Evaluates cursor position to expand on top-notch hover or schedule collapse on drawer exit.
    public func handleMouseLocation(_ point: NSPoint) {
        let screens = NSScreen.screens

        if !isExpanded {
            if let matchedScreen = screens.first(where: { Self.isPointInTopTriggerZone(point, screenFrame: $0.frame) }) {
                hoverCollapseTask?.cancel()
                hoverCollapseTask = nil
                openedViaHover = true
                activeScreen = matchedScreen
                setExpanded(true, activateApp: false, on: matchedScreen)
            } else if screens.isEmpty {
                let fallbackFrame = resolvedTargetScreen()?.frame
                    ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                if Self.isPointInTopTriggerZone(point, screenFrame: fallbackFrame) {
                    hoverCollapseTask?.cancel()
                    hoverCollapseTask = nil
                    openedViaHover = true
                    setExpanded(true, activateApp: false, on: nil)
                }
            }
            return
        }

        let currentScreenFrame = resolvedTargetScreen()?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let insideDrawer = Self.isPointInsideExpandedDrawer(point, panelFrame: panel.frame)
        let inTriggerZone = Self.isPointInTopTriggerZone(point, screenFrame: currentScreenFrame)

        if insideDrawer || inTriggerZone {
            hoverCollapseTask?.cancel()
            hoverCollapseTask = nil
            return
        }

        guard openedViaHover,
              !coordinator.overlayStore.isEditingPrompt,
              !coordinator.isSessionActive else {
            return
        }

        if hoverCollapseTask == nil {
            hoverCollapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.hoverCollapseTask = nil

                let currentPoint = NSEvent.mouseLocation
                let targetFrame = self.resolvedTargetScreen()?.frame
                    ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let stillInside = Self.isPointInsideExpandedDrawer(currentPoint, panelFrame: self.panel.frame)
                    || Self.isPointInTopTriggerZone(currentPoint, screenFrame: targetFrame)

                guard self.isExpanded,
                      self.openedViaHover,
                      !stillInside,
                      !self.coordinator.overlayStore.isEditingPrompt,
                      !self.coordinator.isSessionActive else {
                    return
                }
                self.setExpanded(false, activateApp: false)
            }
        }
    }

    private func refreshContentView() {
        let binding = Binding<Bool>(
            get: { [weak self] in self?.isExpanded ?? false },
            set: { [weak self] newValue in self?.setExpanded(newValue) }
        )
        let rootView = NotchAssistantView(
            coordinator: coordinator,
            isExpanded: binding,
            onOpenSettings: { [weak self] in
                self?.handleOpenSettingsFromDrawer()
            },
            onResizeNeeded: { [weak self] expanded in
                self?.updatePanelFrame(expanded: expanded)
            },
            onRequestKeyFocus: { [weak self] in
                self?.pinAndActivateForInteraction()
            }
        )
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hosting = NSHostingController(rootView: rootView)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

            let container = NotchHoverTrackingView(frame: panel.contentView?.bounds ?? .zero)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            container.onHoverEvent = { [weak self] location in
                self?.handleMouseLocation(location)
            }

            hosting.view.frame = container.bounds
            hosting.view.autoresizingMask = [.width, .height]
            container.addSubview(hosting.view)

            panel.contentView = container
            self.trackingContainerView = container
            self.hostingController = hosting
        }
    }

    private func resolvedTargetScreen(preferred: NSScreen? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        if let active = activeScreen, !screens.isEmpty, !screens.contains(where: { $0 === active }) {
            activeScreen = nil
        }
        if let preferred {
            if screens.isEmpty || screens.contains(where: { $0 === preferred }) {
                return preferred
            }
        }
        return activeScreen ?? panel.screen ?? NSScreen.main ?? screens.first
    }

    private func updatePanelFrame(expanded: Bool, on screen: NSScreen? = nil) {
        let targetSize = expanded ? Self.expandedSize : Self.collapsedSize
        let targetScreen = resolvedTargetScreen(preferred: screen)
        let frame = Self.frame(for: targetSize, on: targetScreen)
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    private static func frame(for size: CGSize, on screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screenFrame.midX - size.width * 0.5
        let topOffset: CGFloat = 4
        let y = screenFrame.maxY - size.height - topOffset
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func observeScreenChanges() {
        screenTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            ) {
                guard let self else { return }
                self.updatePanelFrame(expanded: self.isExpanded)
            }
        }
    }
}
