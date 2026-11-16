import AppKit
import SwiftUI

/// Interactive top-center `NSPanel` hosting the Notch Pill and expandable Assistant Drawer.
@MainActor
public final class NotchPanel: NSPanel {
    public var allowKeyFocus: Bool = false
    public override var canBecomeKey: Bool { allowKeyFocus }
    public override var canBecomeMain: Bool { false }
}

/// Manages the interactive camera-notch pill and expandable dark Assistant Drawer independently from the click-through overlay.
@MainActor
public final class NotchPanelWindowController {
    public let panel: NotchPanel
    public private(set) var isExpanded: Bool = false

    private let coordinator: AppCoordinator
    private let onOpenSettings: () -> Void
    private var hostingController: NSHostingController<NotchAssistantView>?
    private var screenTask: Task<Void, Never>?

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
    }

    deinit {
        screenTask?.cancel()
    }

    public func showPill() {
        updatePanelFrame(expanded: isExpanded)
        panel.orderFrontRegardless()
    }

    public func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        panel.allowKeyFocus = expanded
        refreshContentView()
        updatePanelFrame(expanded: expanded)
        if expanded {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFrontRegardless()
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
            onOpenSettings: onOpenSettings,
            onResizeNeeded: { [weak self] expanded in
                self?.updatePanelFrame(expanded: expanded)
            }
        )
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hosting = NSHostingController(rootView: rootView)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentViewController = hosting
            self.hostingController = hosting
        }
    }

    private func updatePanelFrame(expanded: Bool) {
        let targetSize = expanded ? Self.expandedSize : Self.collapsedSize
        let frame = Self.frame(for: targetSize, on: NSScreen.main)
        panel.setFrame(frame, display: true, animate: true)
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
