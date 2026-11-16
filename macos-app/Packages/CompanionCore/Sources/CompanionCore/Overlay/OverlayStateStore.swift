import CoreGraphics
import Foundation
import Observation

/// Chat/transcript entry displayed inside the Notch Assistant Drawer.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let isUser: Bool
    public let text: String
    public let timestamp: Date

    public init(id: UUID = UUID(), isUser: Bool, text: String, timestamp: Date = Date()) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.timestamp = timestamp
    }
}

/// Observable MainActor store holding live visual annotations and HUD state for the overlay window.
@MainActor
@Observable
public final class OverlayStateStore {
    public var hudState: HudState = .idle
    public var transcriptSnippet: String?
    public var dictationText: String = ""
    public var isEditingPrompt: Bool = false
    public var highlights: [DrawCommandMessage] = []
    public var arrows: [DrawCommandMessage] = []
    public var callouts: [DrawCommandMessage] = []
    public var messages: [ChatMessage] = [
        ChatMessage(
            isUser: false,
            text: "Hold or tap Control+Option (⌃⌥) to speak, or ask a question below. Use the top-right gear for Settings & Permissions."
        )
    ]
    @ObservationIgnored public var onHudStateApplied: (@MainActor (HudStateMessage) -> Void)?
    private var stateBeforePrivacyPause: HudState?

    public init() {}

    public func appendChatMessage(isUser: Bool, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(isUser: isUser, text: trimmed))
    }

    public var hasAnnotations: Bool {
        !highlights.isEmpty || !arrows.isEmpty || !callouts.isEmpty
    }

    /// Applies an incoming downstream `DrawCommandMessage` from `agent-sidecar`.
    public func apply(_ command: DrawCommandMessage) {
        switch command.action {
        case .highlightRegion:
            highlights.removeAll { $0.commandId == command.commandId }
            highlights.append(command)
            hudState = .drawing
        case .pointArrow:
            arrows.removeAll { $0.commandId == command.commandId }
            arrows.append(command)
            hudState = .drawing
        case .showStepCallout:
            callouts.removeAll { $0.commandId == command.commandId }
            callouts.append(command)
            hudState = .drawing
        case .clearAnnotations:
            clearAll()
        }
    }

    /// Applies an incoming downstream `HudStateMessage` from `agent-sidecar`.
    public func apply(_ message: HudStateMessage) {
        hudState = message.state
        if let rawSnippet = message.transcriptSnippet {
            let trimmed = rawSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                transcriptSnippet = trimmed
            }
        } else {
            transcriptSnippet = nil
        }
        onHudStateApplied?(message)
    }

    /// Removes all active visual annotations and resets HUD state to `.idle` when appropriate.
    public func clearAll() {
        highlights.removeAll()
        arrows.removeAll()
        callouts.removeAll()
        if hudState == .drawing {
            hudState = .idle
        }
    }

    /// Clears active visual annotations in response to a downstream `barge_in` interruption.
    public func handleBargeIn(_ message: BargeInMessage = BargeInMessage()) {
        highlights.removeAll()
        arrows.removeAll()
        callouts.removeAll()
        if hudState == .drawing {
            hudState = message.reason == .vadInterrupted ? .listening : .idle
        }
    }

    /// Enters or exits `.privacyPaused` when a protected bundle ID becomes frontmost.
    public func setPrivacyPaused(_ paused: Bool, appName: String? = nil) {
        if paused {
            if hudState != .privacyPaused {
                stateBeforePrivacyPause = hudState
            }
            highlights.removeAll()
            arrows.removeAll()
            callouts.removeAll()
            hudState = .privacyPaused
            transcriptSnippet = appName.map { "Paused for \($0)" } ?? "Privacy filter active"
        } else if hudState == .privacyPaused {
            let restored = stateBeforePrivacyPause ?? .idle
            hudState = (restored == .drawing) ? .idle : restored
            stateBeforePrivacyPause = nil
            transcriptSnippet = nil
        }
    }

    /// Populates sample annotations scaled to `screenSize` so the menu bar trigger can demo Phase 2 visuals.
    public func loadDemoAnnotations(for screenSize: CGSize) {
        clearAll()

        let w = max(800, Int(screenSize.width))
        let h = max(600, Int(screenSize.height))

        let targetBox = PixelRect(
            x: Int(Double(w) * 0.24),
            y: Int(Double(h) * 0.22),
            width: min(320, Int(Double(w) * 0.24)),
            height: 64
        )
        let secondaryBox = PixelRect(
            x: Int(Double(w) * 0.56),
            y: Int(Double(h) * 0.44),
            width: 220,
            height: 52
        )

        apply(DrawCommandMessage(
            commandId: "demo-highlight-1",
            action: .highlightRegion,
            pixelRect: targetBox,
            label: "Search & Filter Bar",
            color: "#3B82F6",
            style: "pulse"
        ))

        apply(DrawCommandMessage(
            commandId: "demo-arrow-1",
            action: .pointArrow,
            fromPoint: Point2D(
                x: secondaryBox.x + secondaryBox.width / 2,
                y: secondaryBox.y - 16
            ),
            toPoint: Point2D(
                x: targetBox.x + targetBox.width - 24,
                y: targetBox.y + targetBox.height + 8
            ),
            label: "Focus here",
            color: "#10B981"
        ))

        apply(DrawCommandMessage(
            commandId: "demo-callout-1",
            action: .showStepCallout,
            pixelRect: secondaryBox,
            label: "Click-Through Overlay Active",
            stepNumber: 1,
            explanation: "Core Animation highlights and SwiftUI callouts float above apps without stealing focus. Hold Control+Option in Phase 4 to speak.",
            color: "#3B82F6"
        ))

        transcriptSnippet = "Demo: Highlighting target UI region without blocking clicks"
    }
}
