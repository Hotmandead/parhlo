import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Screen rectangle in top-left origin pixel coordinates matching Python `schemas.PixelRect`.
public struct PixelRect: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

/// 2D point in top-left origin pixel coordinates matching Python `schemas.Point2D`.
public struct Point2D: Codable, Sendable, Equatable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// Supported visual annotation actions emitted by `agent-sidecar`.
public enum DrawAction: String, Codable, Sendable, Equatable {
    case highlightRegion = "highlight_region"
    case pointArrow = "point_arrow"
    case showStepCallout = "show_step_callout"
    case clearAnnotations = "clear_annotations"
}

/// Downstream visual annotation command matching Python `schemas.DrawCommandMessage`.
public struct DrawCommandMessage: Codable, Sendable, Equatable, Identifiable {
    public let type: String
    public let commandId: String
    public let action: DrawAction
    public let pixelRect: PixelRect?
    public let fromPoint: Point2D?
    public let toPoint: Point2D?
    public let label: String?
    public let stepNumber: Int?
    public let explanation: String?
    public let color: String
    public let style: String?
    public let matchedAxRole: String?
    public let matchedAxTitle: String?

    public var id: String { commandId }

    enum CodingKeys: String, CodingKey {
        case type
        case commandId = "command_id"
        case action
        case pixelRect = "pixel_rect"
        case fromPoint = "from_point"
        case toPoint = "to_point"
        case label
        case stepNumber = "step_number"
        case explanation
        case color
        case style
        case matchedAxRole = "matched_ax_role"
        case matchedAxTitle = "matched_ax_title"
    }

    public init(
        type: String = "draw_command",
        commandId: String,
        action: DrawAction,
        pixelRect: PixelRect? = nil,
        fromPoint: Point2D? = nil,
        toPoint: Point2D? = nil,
        label: String? = nil,
        stepNumber: Int? = nil,
        explanation: String? = nil,
        color: String = "#3B82F6",
        style: String? = nil,
        matchedAxRole: String? = nil,
        matchedAxTitle: String? = nil
    ) {
        self.type = type
        self.commandId = commandId
        self.action = action
        self.pixelRect = pixelRect
        self.fromPoint = fromPoint
        self.toPoint = toPoint
        self.label = label
        self.stepNumber = stepNumber
        self.explanation = explanation
        self.color = color
        self.style = style
        self.matchedAxRole = matchedAxRole
        self.matchedAxTitle = matchedAxTitle
    }
}

/// Companion session status matching Python `schemas.HudStateMessage.state`.
public enum HudState: String, Codable, Sendable, Equatable {
    case idle
    case listening
    case thinking
    case drawing
    case privacyPaused = "privacy_paused"

    public var displayTitle: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .drawing: "Drawing"
        case .privacyPaused: "Privacy Paused"
        }
    }
}

/// Downstream HUD status update matching Python `schemas.HudStateMessage`.
public struct HudStateMessage: Codable, Sendable, Equatable {
    public let type: String
    public let state: HudState
    public let transcriptSnippet: String?

    enum CodingKeys: String, CodingKey {
        case type
        case state
        case transcriptSnippet = "transcript_snippet"
    }

    public init(
        type: String = "hud_state",
        state: HudState,
        transcriptSnippet: String? = nil
    ) {
        self.type = type
        self.state = state
        self.transcriptSnippet = transcriptSnippet
    }
}

/// Converts top-left origin wire coordinates to AppKit/CoreAnimation bottom-left coordinates.
public enum CoordinateConverter {
    /// Converts a top-left origin `PixelRect` into a local AppKit `CGRect` inside a view of `containerSize`.
    public static func toAppKitLocalRect(_ rect: PixelRect, in containerSize: CGSize) -> CGRect {
        let x = CGFloat(rect.x)
        let height = CGFloat(rect.height)
        let y = containerSize.height - CGFloat(rect.y) - height
        return CGRect(x: x, y: y, width: CGFloat(rect.width), height: height)
    }

    /// Converts a top-left origin `Point2D` into a local AppKit `CGPoint` inside a view of `containerSize`.
    public static func toAppKitLocalPoint(_ point: Point2D, in containerSize: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x),
            y: containerSize.height - CGFloat(point.y)
        )
    }

    /// Converts a top-left origin `PixelRect` into SwiftUI top-left local `CGRect` (clamped inside `containerSize`).
    public static func toSwiftUIRect(_ rect: PixelRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.x),
            y: CGFloat(rect.y),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }
}

/// Parses `#RRGGBB` hex strings safely with a default Parhlo blue fallback.
public enum HexColorParser {
    public static func nsColor(from hex: String, fallback: NSColor = .systemBlue) -> NSColor {
        guard let rgb = parseRGB(hex) else { return fallback }
        return NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
    }

    public static func swiftUIColor(from hex: String, fallback: Color = .blue) -> Color {
        guard let rgb = parseRGB(hex) else { return fallback }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    private static func parseRGB(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return (r, g, b)
    }
}
