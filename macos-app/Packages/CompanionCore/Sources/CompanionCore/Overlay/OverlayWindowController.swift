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

    public init(store: OverlayStateStore, screen: NSScreen? = NSScreen.main) {
        self.store = store
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
        syncFrameToMainScreen()
        window.orderFrontRegardless()
    }

    public func hideOverlay() {
        window.orderOut(nil)
    }

    public func syncFrameToMainScreen() {
        guard let screen = NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func observeScreenChanges() {
        screenTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            ) {
                self?.syncFrameToMainScreen()
            }
        }
    }
}
