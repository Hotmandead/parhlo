import AppKit
import SwiftUI

/// Non-activating transparent overlay window that passes all mouse/keyboard events through.
@MainActor
public final class OverlayWindow: NSWindow {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Manages the borderless full-screen click-through overlay `NSWindow`.
@MainActor
public final class OverlayWindowController {
    public let window: OverlayWindow
    public let store: OverlayStateStore
    private var screenTask: Task<Void, Never>?
    private var pinnedDisplayID: CGDirectDisplayID?

    public init(store: OverlayStateStore, screen: NSScreen? = NSScreen.main) {
        self.store = store
        if let screen, screen !== NSScreen.main {
            self.pinnedDisplayID = Self.displayID(for: screen)
        }
        let targetFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let overlayWindow = OverlayWindow(
            contentRect: targetFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.level = .statusBar
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Set legacy flag; Phase 3 CaptureEngine also excludes Parhlo via SCContentFilter.
        overlayWindow.sharingType = .none

        let hostingView = NSHostingView(rootView: OverlayCanvasView(store: store))
        hostingView.frame = NSRect(origin: .zero, size: targetFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        overlayWindow.contentView = hostingView

        self.window = overlayWindow
        observeScreenChanges()
    }

    deinit {
        screenTask?.cancel()
    }

    public var currentOverlaySize: CGSize {
        window.frame.size
    }

    public func showOverlay() {
        syncFrameToTargetScreen()
        window.orderFrontRegardless()
    }

    public func hideOverlay() {
        window.orderOut(nil)
    }

    public func syncFrameToMainScreen() {
        pinnedDisplayID = nil
        applyScreenFrame(NSScreen.main ?? NSScreen.screens.first)
    }

    /// Pins and syncs the overlay window frame to a specific `NSScreen` (or clears pin when `nil`).
    public func syncFrame(to screen: NSScreen?) {
        pinnedDisplayID = screen.flatMap(Self.displayID(for:))
        applyScreenFrame(screen ?? NSScreen.main ?? NSScreen.screens.first)
    }

    /// Pins and syncs the overlay window frame to the `NSScreen` matching `displayID`.
    public func syncFrame(toDisplayID displayID: CGDirectDisplayID) {
        pinnedDisplayID = displayID
        let matched = NSScreen.screens.first { Self.displayID(for: $0) == displayID }
        applyScreenFrame(matched ?? NSScreen.main ?? NSScreen.screens.first)
    }

    private func syncFrameToTargetScreen() {
        if let pinnedDisplayID,
           let pinnedScreen = NSScreen.screens.first(where: { Self.displayID(for: $0) == pinnedDisplayID }) {
            applyScreenFrame(pinnedScreen)
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(mouseLocation) }
        applyScreenFrame(cursorScreen ?? NSScreen.main ?? NSScreen.screens.first)
    }

    private func applyScreenFrame(_ screen: NSScreen?) {
        guard let screen else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func observeScreenChanges() {
        screenTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            ) {
                self?.syncFrameToTargetScreen()
            }
        }
    }
}
