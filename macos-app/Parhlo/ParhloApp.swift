import AppKit
import CompanionCore
import SwiftUI

@main
@MainActor
final class ParhloAppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: ParhloAppDelegate?

    private var statusItem: NSStatusItem?
    private let coordinator = AppCoordinator()
    private var notchPanelController: NotchPanelWindowController?
    private var settingsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = ParhloAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
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
            button.toolTip = "Parhlo — Click for Assistant Drawer, Right-Click for Voice & Menu (⌃⌥)"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusMenu(from: sender)
        } else {
            toggleAssistantDrawer()
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let voiceTitle = coordinator.isSessionActive
            ? "Stop Voice Session (⌃⌥)"
            : "Start Voice Session (⌃⌥)"
        let voiceItem = NSMenuItem(title: voiceTitle, action: #selector(toggleVoiceSession), keyEquivalent: "")
        voiceItem.target = self
        menu.addItem(voiceItem)

        let drawerTitle = (notchPanelController?.isExpanded == true)
            ? "Collapse Assistant Drawer"
            : "Open Assistant Drawer"
        let drawerItem = NSMenuItem(title: drawerTitle, action: #selector(toggleAssistantDrawer), keyEquivalent: "")
        drawerItem.target = self
        menu.addItem(drawerItem)

        menu.addItem(.separator())

        let demoItem = NSMenuItem(title: "Demo Visual Annotations", action: #selector(triggerDemoFromMenu), keyEquivalent: "")
        demoItem.target = self
        menu.addItem(demoItem)

        let clearItem = NSMenuItem(title: "Clear Overlay", action: #selector(clearOverlayFromMenu), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let settingsItem = NSMenuItem(title: "Settings & Permissions…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Parhlo", action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleVoiceSession() {
        coordinator.toggleSession()
    }

    @objc private func triggerDemoFromMenu() {
        coordinator.triggerDemoAnnotations()
    }

    @objc private func clearOverlayFromMenu() {
        coordinator.clearOverlay()
    }

    @objc private func quitFromMenu() {
        quitApplication()
    }

    @objc private func toggleAssistantDrawer() {
        notchPanelController?.toggleExpanded()
    }

    @objc private func openSettingsWindow() {
        coordinator.permissionsManager.refresh()
        notchPanelController?.setExpanded(false, activateApp: false)

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
