import AppKit
import SwiftUI

/// Tabs inside the top Notch Assistant Drawer.
public enum AssistantDrawerTab: String, Sendable {
    case voice
    case chat
}

/// Sleek dark notch-hugging pill that expands into a dotted-grid voice/chat assistant drawer.
public struct NotchAssistantView: View {
    @Bindable private var coordinator: AppCoordinator
    @Bindable private var overlayStore: OverlayStateStore
    @Binding private var isExpanded: Bool
    private let onOpenSettings: () -> Void
    private let onResizeNeeded: (Bool) -> Void
    private let onRequestKeyFocus: () -> Void

    @State private var selectedTab: AssistantDrawerTab = .chat
    @FocusState private var isPromptFocused: Bool

    public init(
        coordinator: AppCoordinator,
        isExpanded: Binding<Bool>,
        onOpenSettings: @escaping () -> Void,
        onResizeNeeded: @escaping (Bool) -> Void,
        onRequestKeyFocus: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.overlayStore = coordinator.overlayStore
        self._isExpanded = isExpanded
        self.onOpenSettings = onOpenSettings
        self.onResizeNeeded = onResizeNeeded
        self.onRequestKeyFocus = onRequestKeyFocus
    }

    public var body: some View {
        Group {
            if isExpanded {
                expandedDrawer
            } else {
                collapsedNotchPill
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: isPromptFocused) { _, newValue in
            coordinator.overlayStore.isEditingPrompt = newValue
            if newValue {
                onRequestKeyFocus()
            }
        }
        .onChange(of: coordinator.overlayStore.dictationText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               selectedTab != .chat {
                selectedTab = .chat
            }
        }
    }

    // MARK: - Collapsed Camera-Notch Pill

    private var collapsedNotchPill: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                isExpanded = true
                onResizeNeeded(true)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.85), radius: 4)

                Image(systemName: coordinator.isSessionActive ? "waveform" : "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Parhlo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                if coordinator.overlayStore.hudState == .privacyPaused {
                    Text("· Privacy Paused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                } else if isListeningStatus {
                    Text("· Listening…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green.opacity(0.92))
                } else if coordinator.overlayStore.hudState != .idle {
                    Text("· \(coordinator.overlayStore.hudState.displayTitle)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.95))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Dark Dotted-Grid Assistant Drawer

    private var expandedDrawer: some View {
        VStack(spacing: 0) {
            topToolbar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Group {
                switch selectedTab {
                case .voice:
                    voiceCanvas
                case .chat:
                    chatCanvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomComposerDock
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(width: 540, height: 440)
        .background(
            ZStack {
                Color(red: 0.065, green: 0.07, blue: 0.085)
                DottedGridBackground()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
    }

    private var topToolbar: some View {
        HStack {
            // Left: Voice / Chat pill toggle matching competitor screenshot.
            HStack(spacing: 2) {
                toolbarTabButton(icon: "waveform", tab: .voice)
                toolbarTabButton(icon: "bubble.left.fill", tab: .chat)
            }
            .padding(3)
            .background(Color.white.opacity(0.08), in: Capsule())

            Spacer()

            // Center status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(drawerStatusTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer()

            // Right: Demo, Settings Gear, Collapse
            HStack(spacing: 8) {
                circularToolbarButton(icon: "sparkles", help: "Demo Visual Annotations") {
                    coordinator.triggerDemoAnnotations()
                }
                circularToolbarButton(icon: "gearshape.fill", help: "Settings & Permissions") {
                    onOpenSettings()
                }
                circularToolbarButton(icon: "arrow.down.right.and.arrow.up.left", help: "Collapse to Notch Pill") {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                        isExpanded = false
                        onResizeNeeded(false)
                    }
                }
            }
        }
    }

    private func toolbarTabButton(icon: String, tab: AssistantDrawerTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .frame(width: 30, height: 24)
                .background(isSelected ? Color.white.opacity(0.18) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func circularToolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var chatCanvas: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Text("Today \(Date().formatted(date: .omitted, time: .shortened))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.top, 4)

                    ForEach(coordinator.overlayStore.messages) { msg in
                        chatBubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: coordinator.overlayStore.messages.count) { _, _ in
                if let last = coordinator.overlayStore.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.isUser {
                Spacer(minLength: 72)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(msg.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.43, green: 0.68, blue: 0.98),
                                    Color(red: 0.25, green: 0.50, blue: 0.94)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    Text("Read")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else {
                Text(msg.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Color(red: 0.16, green: 0.17, blue: 0.20).opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                Spacer(minLength: 72)
            }
        }
    }

    private var voiceCanvas: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 92, height: 92)
                Circle()
                    .strokeBorder(statusColor.opacity(0.65), lineWidth: 2)
                    .frame(width: 72, height: 72)
                Image(systemName: coordinator.isSessionActive ? "waveform" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 4) {
                Text(coordinator.isSessionActive ? "Listening via Control+Option" : "Voice Companion Ready")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(
                    coordinator.overlayStore.transcriptSnippet
                        ?? "Tap the mic or press Control+Option (⌃⌥) to explain what's on screen."
                )
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            }

            HStack(spacing: 10) {
                Button(coordinator.isSessionActive ? "Stop Session" : "Start Voice (⌃⌥)") {
                    coordinator.toggleSession()
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.isSessionActive ? .red : .blue)

                Button("Demo Overlays") {
                    coordinator.triggerDemoAnnotations()
                }
                .buttonStyle(.bordered)

                if coordinator.overlayStore.hasAnnotations {
                    Button("Clear") {
                        coordinator.clearOverlay()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
    }

    private var bottomComposerDock: some View {
        HStack(spacing: 10) {
            // Left glowing circular mic trigger
            Button {
                coordinator.toggleSession()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: coordinator.isSessionActive
                                    ? [Color.green, Color(red: 0.1, green: 0.65, blue: 0.35)]
                                    : [Color(red: 0.72, green: 0.84, blue: 0.99), Color(red: 0.38, green: 0.58, blue: 0.92)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 38, height: 38)
                        .shadow(
                            color: (coordinator.isSessionActive ? Color.green : Color.blue).opacity(0.45),
                            radius: 8
                        )
                    Image(systemName: coordinator.isSessionActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(coordinator.isSessionActive ? .white : Color(red: 0.08, green: 0.12, blue: 0.22))
                }
            }
            .buttonStyle(.plain)
            .help("Toggle Voice Session (Control+Option)")

            // Center capsule prompt input bar
            HStack(spacing: 8) {
                Menu {
                    Button("Demo Visual Annotations") { coordinator.triggerDemoAnnotations() }
                    Button("Clear Overlay") { coordinator.clearOverlay() }
                    Divider()
                    Button("Settings & Permissions…") { onOpenSettings() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)

                TextField(
                    coordinator.isSessionActive ? "Listening… (Ask Parhlo…)" : "Ask Parhlo…",
                    text: $overlayStore.dictationText
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($isPromptFocused)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onRequestKeyFocus()
                        }
                    )
                    .onSubmit { submitPrompt() }

                Button {
                    coordinator.setOutputMuted(!coordinator.audioManager.isOutputMuted)
                } label: {
                    Image(systemName: coordinator.audioManager.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Mute / Barge-In Playback")

                Button {
                    submitPrompt()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            coordinator.overlayStore.dictationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.white.opacity(0.16)
                                : Color.blue,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color(red: 0.42, green: 0.62, blue: 0.96).opacity(0.55), lineWidth: 1)
            )
        }
    }

    private func submitPrompt() {
        let text = coordinator.overlayStore.dictationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        selectedTab = .chat
        coordinator.sendTextPrompt(text)
    }

    private var isListeningStatus: Bool {
        coordinator.overlayStore.hudState == .listening
            || (coordinator.isSessionActive && coordinator.overlayStore.hudState == .idle)
            || (!coordinator.overlayStore.dictationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && coordinator.overlayStore.hudState == .idle)
    }

    private var drawerStatusTitle: String {
        if isListeningStatus {
            return "Listening…"
        }
        return coordinator.overlayStore.hudState.displayTitle
    }

    private var statusColor: Color {
        switch coordinator.overlayStore.hudState {
        case .idle: coordinator.isSessionActive ? .green : .blue
        case .listening: .green
        case .thinking: .orange
        case .drawing: .blue
        case .privacyPaused: .red
        }
    }
}

private struct DottedGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            let dotSize: CGFloat = 1.4
            let color = Color.white.opacity(0.07)
            var y: CGFloat = 10
            while y < size.height {
                var x: CGFloat = 10
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                        with: .color(color)
                    )
                    x += spacing
                }
                y += spacing
            }
        }
    }
}
