import SwiftUI

/// Onboarding view displaying live TCC permission statuses and quick System Settings links.
public struct PermissionsOnboardingView: View {
    @Bindable private var manager: PermissionsManager

    public init(manager: PermissionsManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parhlo Permissions")
                        .font(.title2.weight(.semibold))
                    Text("Grant native macOS access for capture, UI snapping, and voice.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !manager.allGranted {
                    Button("Request All Missing") {
                        requestAllMissing()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            VStack(spacing: 12) {
                PermissionRow(
                    title: "Screen Recording",
                    subtitle: "On-demand <= 1 FPS capture via ScreenCaptureKit (redacted on-device).",
                    status: manager.screenRecording,
                    onRequest: { manager.requestScreenRecording() },
                    onOpenSettings: { manager.openSystemSettings(for: .screenCapture) }
                )

                PermissionRow(
                    title: "Accessibility (AXUIElement)",
                    subtitle: "Snaps highlights and arrows accurately to visible UI controls.",
                    status: manager.accessibility,
                    onRequest: { manager.requestAccessibility() },
                    onOpenSettings: { manager.openSystemSettings(for: .accessibility) }
                )

                PermissionRow(
                    title: "Microphone",
                    subtitle: "Low-latency 16 kHz voice input activated via Control+Option.",
                    status: manager.microphone,
                    onRequest: {
                        Task {
                            await manager.requestMicrophone()
                        }
                    },
                    onOpenSettings: { manager.openSystemSettings(for: .microphone) }
                )

                PermissionRow(
                    title: "Speech Recognition",
                    subtitle: "On-device speech-to-text populating the Ask Parhlo input bar.",
                    status: manager.speechRecognition,
                    onRequest: {
                        Task {
                            await manager.requestSpeechRecognition()
                        }
                    },
                    onOpenSettings: { manager.openSystemSettings(for: .speechRecognition) }
                )
            }

            HStack(alignment: .center, spacing: 12) {
                if manager.allGranted {
                    Label("All permissions granted", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("Tip: If you already toggled a permission ON in System Settings after a rebuild, remove (-) Parhlo in System Settings and re-add it, then relaunch Parhlo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Refresh Status") {
                    manager.refresh()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            manager.refresh()
        }
    }

    private func requestAllMissing() {
        Task { @MainActor in
            if manager.screenRecording != .granted {
                manager.requestScreenRecording()
            }
            if manager.accessibility != .granted {
                manager.requestAccessibility()
            }
            if manager.microphone != .granted {
                await manager.requestMicrophone()
            }
            if manager.speechRecognition != .granted {
                await manager.requestSpeechRecognition()
            }
            manager.refresh()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let status: PermissionStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    statusBadge
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status != .granted {
                Button("Request", action: onRequest)
                    .buttonStyle(.borderedProminent)
            }
            Button("Settings", action: onOpenSettings)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusBadge: some View {
        let color: Color = switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        }
        return Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
