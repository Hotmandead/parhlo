import AppKit
import CompanionCore
import SwiftUI

@main
@MainActor
final class ParhloAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let coordinator = AppCoordinator()
    private var notchPanelController: NotchPanelWindowController?
    private var settingsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = ParhloAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.bootstrap()

        let notch = NotchPanelWindowController(coordinator: coordinator) { [weak self] in
            self?.openSettingsWindow()
        }
        notch.showPill()
        notchPanelController = notch

        setupMenuBarItem()
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "sparkles.rectangle.stack",
                accessibilityDescription: "Parhlo"
            )
            button.toolTip = "Parhlo — Click to open Assistant Drawer (⌃⌥ to Speak)"
            button.target = self
            button.action = #selector(toggleAssistantDrawer)
        }
        statusItem = item
    }

    @objc private func toggleAssistantDrawer() {
        notchPanelController?.toggleExpanded()
    }

    @objc private func openSettingsWindow() {
        coordinator.permissionsManager.refresh()

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(coordinator: coordinator) { [weak self] in
                self?.quitApplication()
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Parhlo Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.085, blue: 0.10, alpha: 1.0)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func quitApplication() {
        coordinator.stopSession()
        NSApp.terminate(nil)
    }
}
