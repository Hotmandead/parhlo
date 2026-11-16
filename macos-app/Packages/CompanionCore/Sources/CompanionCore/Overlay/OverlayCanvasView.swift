import SwiftUI

/// Full-screen SwiftUI canvas combining Core Animation vectors, step callouts, and capture feedback.
public struct OverlayCanvasView: View {
    @Bindable private var store: OverlayStateStore
    @State private var captureBorderOpacity: Double = 0.0

    public init(store: OverlayStateStore) {
        self.store = store
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                VectorAnnotationLayerView(
                    highlights: store.highlights,
                    arrows: store.arrows
                )
                .ignoresSafeArea()

                // Subtle non-activating screen-edge shimmer showing on-demand capture occurred.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.85),
                                Color.blue.opacity(0.75),
                                Color.green.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .shadow(color: Color.cyan.opacity(0.55), radius: 12)
                    .padding(6)
                    .opacity(captureBorderOpacity)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                ForEach(store.callouts) { callout in
                    StepCalloutCardView(callout: callout, containerSize: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeOut(duration: 0.18), value: store.callouts.count)
            .onChange(of: store.capturePulseID) { _, _ in
                captureBorderOpacity = 0.9
                withAnimation(.easeOut(duration: 0.55)) {
                    captureBorderOpacity = 0.0
                }
            }
        }
        .background(Color.clear)
    }
}

/// Glassmorphic floating explanation card anchored near a `show_step_callout` target box.
public struct StepCalloutCardView: View {
    public let callout: DrawCommandMessage
    public let containerSize: CGSize

    private let cardWidth: CGFloat = 300

    public init(callout: DrawCommandMessage, containerSize: CGSize) {
        self.callout = callout
        self.containerSize = containerSize
    }

    public var body: some View {
        let accent = HexColorParser.swiftUIColor(from: callout.color)
        let position = resolvedCenterPosition()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let step = callout.stepNumber {
                    Text("Step \(step)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent, in: Capsule())
                        .foregroundStyle(.white)
                }
                if let title = callout.label, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }

            if let explanation = callout.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: cardWidth, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(0.65), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        .position(position)
    }

    private func resolvedCenterPosition() -> CGPoint {
        guard let pixelRect = callout.pixelRect else {
            return CGPoint(x: containerSize.width * 0.5, y: containerSize.height * 0.25)
        }
        let target = CoordinateConverter.toSwiftUIRect(pixelRect)
        let rawX = target.midX
        let rawY = target.maxY + 64
        let halfW = cardWidth * 0.5 + 16
        let clampedX = min(max(halfW, rawX), max(halfW, containerSize.width - halfW))
        let clampedY = min(max(70, rawY), max(70, containerSize.height - 90))
        return CGPoint(x: clampedX, y: clampedY)
    }
}

/// Sleek dark notch-aligned HUD pill communicating live voice, thinking, drawing, or privacy-paused status.
public struct CursorHUDView: View {
    public let state: HudState
    public let transcriptSnippet: String?

    public init(state: HudState, transcriptSnippet: String?) {
        self.state = state
        self.transcriptSnippet = transcriptSnippet
    }

    public var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .shadow(color: indicatorColor.opacity(0.8), radius: 4)

            Text("Parhlo · \(state.displayTitle)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            if let snippet = transcriptSnippet, !snippet.isEmpty {
                Divider()
                    .frame(height: 12)
                    .overlay(Color.white.opacity(0.22))
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.84))
                .background(.ultraThinMaterial, in: Capsule())
        )
        .overlay(
            Capsule()
                .strokeBorder(indicatorColor.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 6)
    }

    private var indicatorColor: Color {
        switch state {
        case .idle: .gray
        case .listening: .green
        case .thinking: .orange
        case .drawing: .blue
        case .privacyPaused: .red
        }
    }
}
