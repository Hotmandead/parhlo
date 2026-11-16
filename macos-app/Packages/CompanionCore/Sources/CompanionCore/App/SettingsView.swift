import AppKit
import SwiftUI

/// Sidebar sections for Parhlo's dark macOS Settings window.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case voice
    case shortcuts
    case privacy
    case permissions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .voice: "Voice & Mic"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .permissions: "Permissions"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .voice: "waveform"
        case .shortcuts: "command"
        case .privacy: "hand.raised.fill"
        case .permissions: "lock.shield.fill"
        }
    }
}

/// Dark sidebar Preferences window matching the Parhlo design language.
public struct SettingsView: View {
    @Bindable private var coordinator: AppCoordinator
    private let onQuit: () -> Void
    @State private var selectedTab: SettingsTab = .general

    public init(coordinator: AppCoordinator, onQuit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.coordinator = coordinator
        self.onQuit = onQuit
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .overlay(Color.white.opacity(0.08))
            detailPane
        }
        .frame(width: 780, height: 520)
        .background(Color(red: 0.08, green: 0.085, blue: 0.10))
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PARHLO")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ForEach(SettingsTab.allCases) { tab in
                let selected = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(tab.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        selected ? Color.white.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                onQuit()
            } label: {
                Text("Quit Parhlo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.36))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Text("Parhlo 0.1.0")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 205)
        .background(Color(red: 0.065, green: 0.07, blue: 0.082))
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedTab {
                case .general:
                    generalTab
                case .voice:
                    voiceTab
                case .shortcuts:
                    shortcutsTab
                case .privacy:
                    privacyTab
                case .permissions:
                    PermissionsOnboardingView(manager: coordinator.permissionsManager)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "General",
                subtitle: "Local Gemini Live sidecar bridge and active companion session."
            )

            darkCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sidecar WebSocket")
                                .font(.headline)
                            Text(coordinator.webSocketClient.url.absoluteString)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text(coordinator.webSocketClient.connectionState.displayTitle)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(connectionColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(connectionColor)
                    }

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack(spacing: 12) {
                        Button {
                            coordinator.toggleSession()
                        } label: {
                            Text(coordinator.isSessionActive ? "Stop Voice Session" : "Start Voice Session")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(
                                    LinearGradient(
                                        colors: coordinator.isSessionActive
                                            ? [Color.red, Color(red: 0.72, green: 0.14, blue: 0.14)]
                                            : [Color(red: 0.43, green: 0.68, blue: 0.98), Color(red: 0.22, green: 0.46, blue: 0.92)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)

                        Button("Demo Visual Annotations") {
                            coordinator.triggerDemoAnnotations()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var voiceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Voice & Microphone",
                subtitle: "Full-duplex 16 kHz capture and 24 kHz Gemini playback with hardware AEC."
            )

            darkCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Hardware Voice Processing (Echo Cancellation)", isOn: Binding(
                        get: { coordinator.audioManager.voiceProcessingEnabled },
                        set: { coordinator.audioManager.voiceProcessingEnabled = $0 }
                    ))
                    Divider().overlay(Color.white.opacity(0.08))
                    Toggle("Local VAD Pre-Filter (Instant Barge-In)", isOn: Binding(
                        get: { coordinator.audioManager.localVADEnabled },
                        set: { coordinator.audioManager.localVADEnabled = $0 }
                    ))
                    Divider().overlay(Color.white.opacity(0.08))
                    HStack {
                        Text("Audio Pipeline")
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text("16 kHz Mono In → 24 kHz Mono Out")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
    }

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Shortcuts",
                subtitle: "Configure how Control+Option (⌃⌥) activates speaking to Parhlo."
            )

            darkCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Global Voice Hotkey")
                        Spacer()
                        Text("⌃ Control + ⌥ Option")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    Picker("Activation Mode", selection: Binding(
                        get: { coordinator.hotkeyManager.mode },
                        set: { coordinator.hotkeyManager.mode = $0 }
                    )) {
                        ForEach(HotkeyActivationMode.allCases, id: \.self) { mode in
                            Text(mode.displayTitle).tag(mode)
                        }
                    }
                }
            }
        }
    }

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Privacy & On-Device Redaction",
                subtitle: "Capture pauses automatically for password managers and redacts sensitive text locally via Apple Vision."
            )

            darkCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("EXCLUDED BUNDLE IDENTIFIERS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(Array(coordinator.privacyFilter.excludedBundleIDs).sorted(), id: \.self) { bundleID in
                        Text(bundleID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func darkCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.11, green: 0.115, blue: 0.135), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var connectionColor: Color {
        switch coordinator.webSocketClient.connectionState {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .gray
        }
    }
}
