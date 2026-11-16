import Foundation

/// Visible macOS Accessibility element metadata and bounding box matching `schemas.AXElementBounds`.
public struct AXElementBounds: Codable, Sendable, Equatable {
    public let role: String
    public let title: String?
    public let description: String?
    public let value: String?
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        self.role = role
        self.title = title
        self.description = description
        self.value = value
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

/// Session lifecycle actions matching `schemas.SessionControlMessage.action`.
public enum SessionControlAction: String, Codable, Sendable, Equatable {
    case startSession = "start_session"
    case stopSession = "stop_session"
    case bargeInManual = "barge_in_manual"
}

/// Upstream session lifecycle control message matching `schemas.SessionControlMessage`.
public struct SessionControlMessage: Codable, Sendable, Equatable {
    public let type: String
    public let action: SessionControlAction

    public init(type: String = "session_control", action: SessionControlAction) {
        self.type = type
        self.action = action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "session_control"
        self.action = try container.decode(SessionControlAction.self, forKey: .action)
    }
}

/// Upstream redacted JPEG screen frame and AXUIElement snapshot matching `schemas.ScreenContextMessage`.
public struct ScreenContextMessage: Codable, Sendable, Equatable {
    public let type: String
    public let screenWidth: Int
    public let screenHeight: Int
    public let scaleFactor: Double
    public let jpegB64: String
    public let axElements: [AXElementBounds]
    public let frontmostBundleId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case scaleFactor = "scale_factor"
        case jpegB64 = "jpeg_b64"
        case axElements = "ax_elements"
        case frontmostBundleId = "frontmost_bundle_id"
    }

    public init(
        type: String = "screen_context",
        screenWidth: Int,
        screenHeight: Int,
        scaleFactor: Double = 1.0,
        jpegB64: String,
        axElements: [AXElementBounds] = [],
        frontmostBundleId: String? = nil
    ) {
        self.type = type
        self.screenWidth = max(1, screenWidth)
        self.screenHeight = max(1, screenHeight)
        self.scaleFactor = scaleFactor > 0 ? scaleFactor : 1.0
        self.jpegB64 = jpegB64
        self.axElements = axElements
        self.frontmostBundleId = frontmostBundleId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "screen_context"
        self.screenWidth = max(1, try container.decode(Int.self, forKey: .screenWidth))
        self.screenHeight = max(1, try container.decode(Int.self, forKey: .screenHeight))
        let decodedScale = try container.decodeIfPresent(Double.self, forKey: .scaleFactor) ?? 1.0
        self.scaleFactor = decodedScale > 0 ? decodedScale : 1.0
        self.jpegB64 = try container.decode(String.self, forKey: .jpegB64)
        self.axElements = try container.decodeIfPresent([AXElementBounds].self, forKey: .axElements) ?? []
        self.frontmostBundleId = try container.decodeIfPresent(String.self, forKey: .frontmostBundleId)
    }
}

/// Upstream 16 kHz 16-bit mono PCM microphone audio chunk matching `schemas.AudioUpMessage`.
public struct AudioUpMessage: Codable, Sendable, Equatable {
    public let type: String
    public let pcmB64: String

    enum CodingKeys: String, CodingKey {
        case type
        case pcmB64 = "pcm_b64"
    }

    public init(type: String = "audio_up", pcmB64: String) {
        self.type = type
        self.pcmB64 = pcmB64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "audio_up"
        self.pcmB64 = try container.decode(String.self, forKey: .pcmB64)
    }
}

/// Upstream typed or dictated text prompt matching `schemas.TextUpMessage`.
public struct TextUpMessage: Codable, Sendable, Equatable {
    public let type: String
    public let text: String

    public init(type: String = "text_up", text: String) {
        self.type = type
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text_up"
        self.text = try container.decode(String.self, forKey: .text)
    }
}

/// Discriminated union of all upstream messages sent from `macos-app` to `agent-sidecar`.
public enum UpstreamMessage: Codable, Sendable, Equatable {
    case sessionControl(SessionControlMessage)
    case screenContext(ScreenContextMessage)
    case audioUp(AudioUpMessage)
    case textUp(TextUpMessage)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "session_control":
            self = .sessionControl(try SessionControlMessage(from: decoder))
        case "screen_context":
            self = .screenContext(try ScreenContextMessage(from: decoder))
        case "audio_up":
            self = .audioUp(try AudioUpMessage(from: decoder))
        case "text_up":
            self = .textUp(try TextUpMessage(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown upstream message type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .sessionControl(let message):
            try message.encode(to: encoder)
        case .screenContext(let message):
            try message.encode(to: encoder)
        case .audioUp(let message):
            try message.encode(to: encoder)
        case .textUp(let message):
            try message.encode(to: encoder)
        }
    }
}

/// Downstream 24 kHz 16-bit mono PCM Gemini voice chunk matching `schemas.AudioDownMessage`.
public struct AudioDownMessage: Codable, Sendable, Equatable {
    public let type: String
    public let pcmB64: String

    enum CodingKeys: String, CodingKey {
        case type
        case pcmB64 = "pcm_b64"
    }

    public init(type: String = "audio_down", pcmB64: String) {
        self.type = type
        self.pcmB64 = pcmB64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "audio_down"
        self.pcmB64 = try container.decode(String.self, forKey: .pcmB64)
    }
}

/// Reason for a downstream interruption signal matching `schemas.BargeInMessage.reason`.
public enum BargeInReason: String, Codable, Sendable, Equatable {
    case vadInterrupted = "vad_interrupted"
    case manual = "manual"
}

/// Downstream interruption signal matching `schemas.BargeInMessage`.
public struct BargeInMessage: Codable, Sendable, Equatable {
    public let type: String
    public let reason: BargeInReason

    enum CodingKeys: String, CodingKey {
        case type
        case reason
    }

    public init(type: String = "barge_in", reason: BargeInReason = .vadInterrupted) {
        self.type = type
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "barge_in"
        self.reason = try container.decodeIfPresent(BargeInReason.self, forKey: .reason) ?? .vadInterrupted
    }
}

/// Discriminated union of all downstream messages sent from `agent-sidecar` to `macos-app`.
public enum DownstreamEvent: Codable, Sendable, Equatable {
    case drawCommand(DrawCommandMessage)
    case audioDown(AudioDownMessage)
    case bargeIn(BargeInMessage)
    case hudState(HudStateMessage)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "draw_command":
            self = .drawCommand(try DrawCommandMessage(from: decoder))
        case "audio_down":
            self = .audioDown(try AudioDownMessage(from: decoder))
        case "barge_in":
            self = .bargeIn(try BargeInMessage(from: decoder))
        case "hud_state":
            self = .hudState(try HudStateMessage(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown downstream message type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .drawCommand(let message):
            try message.encode(to: encoder)
        case .audioDown(let message):
            try message.encode(to: encoder)
        case .bargeIn(let message):
            try message.encode(to: encoder)
        case .hudState(let message):
            try message.encode(to: encoder)
        }
    }
}
