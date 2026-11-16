import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Controls whether Parhlo routes requests to the Gemini Live sidecar, on-device offline engine, or auto-fallback.
public enum AssistantBackendMode: String, CaseIterable, Sendable, Equatable {
    case auto = "auto"
    case offlineOnly = "offline"
    case sidecarOnly = "sidecar"

    public var displayTitle: String {
        switch self {
        case .auto: "Auto (Gemini Live + On-Device Fallback)"
        case .offlineOnly: "Offline On-Device Only"
        case .sidecarOnly: "Gemini Live Sidecar Only"
        }
    }
}

/// Sanitized on-device screen context used to ground offline Q&A without leaving the Mac.
public struct OfflineScreenContext: Sendable, Equatable {
    public let sanitizedOCRText: String
    public let axElements: [AXElementBounds]
    public let frontmostBundleID: String?
    public let frontmostAppName: String?

    public init(
        sanitizedOCRText: String = "",
        axElements: [AXElementBounds] = [],
        frontmostBundleID: String? = nil,
        frontmostAppName: String? = nil
    ) {
        self.sanitizedOCRText = sanitizedOCRText
        self.axElements = axElements
        self.frontmostBundleID = frontmostBundleID
        self.frontmostAppName = frontmostAppName
    }
}

/// Protocol for answering user questions grounded in local screen context.
public protocol OfflineQASession: Sendable {
    func answer(prompt: String, context: OfflineScreenContext) async throws -> String
}

/// On-device screen-grounded assistant using Apple `FoundationModels` when available with a deterministic summary fallback.
public actor OfflineAssistantEngine: OfflineQASession {
    private static let maxAXElementsInPrompt = 25

    public init() {}

    public func answer(prompt: String, context: OfflineScreenContext) async throws -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = trimmedPrompt.isEmpty ? "Summarize what is currently on screen." : trimmedPrompt

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if SystemLanguageModel.default.isAvailable {
                do {
                    let session = LanguageModelSession(
                        instructions: """
                        You are Parhlo, a concise macOS screen-aware assistant running on-device. \
                        Ground your answer strictly in the provided active application, accessibility UI elements, \
                        and sanitized on-screen OCR text. Keep responses clear, direct, and under 4 sentences.
                        """
                    )
                    let groundedPrompt = Self.buildGroundedModelPrompt(
                        prompt: effectivePrompt,
                        context: context
                    )
                    let response = try await session.respond(to: groundedPrompt)
                    let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        return content
                    }
                } catch {
                    // Fall through to deterministic on-device summary fallback when FoundationModels fails.
                }
            }
        }
        #endif

        return Self.buildDeterministicSummary(prompt: effectivePrompt, context: context)
    }

    /// Builds a structured prompt combining the user query, active app metadata, up to 25 AX elements, and sanitized OCR text.
    public static func buildGroundedModelPrompt(prompt: String, context: OfflineScreenContext) -> String {
        let appIdentity = resolvedAppLabel(from: context) ?? "Unknown Application"
        let axSummaryLines = context.axElements
            .prefix(maxAXElementsInPrompt)
            .compactMap(formatAXElement(_:))
        let axSection = axSummaryLines.isEmpty
            ? "None captured"
            : axSummaryLines.joined(separator: "\n")
        let ocrText = context.sanitizedOCRText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrSection = ocrText.isEmpty ? "None captured" : ocrText

        return """
        Active Application: \(appIdentity)

        Visible UI Controls (role: title):
        \(axSection)

        Sanitized Screen OCR Text:
        \(ocrSection)

        User Question:
        \(prompt)
        """
    }

    /// Generates a deterministic, grounded response from local screen context when Apple Intelligence is unavailable.
    public static func buildDeterministicSummary(prompt: String, context: OfflineScreenContext) -> String {
        let keywords = extractKeywords(from: prompt)
        let appLabel = resolvedAppLabel(from: context)

        let formattedElements = context.axElements
            .prefix(maxAXElementsInPrompt)
            .compactMap(formatAXElement(_:))
        let matchingElements: [String]
        if keywords.isEmpty {
            matchingElements = Array(formattedElements.prefix(5))
        } else {
            let filtered = formattedElements.filter { element in
                let lowered = element.lowercased()
                return keywords.contains { lowered.contains($0) }
            }
            matchingElements = filtered.isEmpty
                ? Array(formattedElements.prefix(5))
                : Array(filtered.prefix(6))
        }

        let ocrLines = context.sanitizedOCRText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let matchingOCRLines: [String]
        if keywords.isEmpty {
            matchingOCRLines = Array(ocrLines.prefix(4))
        } else {
            let filtered = ocrLines.filter { line in
                let lowered = line.lowercased()
                return keywords.contains { lowered.contains($0) }
            }
            matchingOCRLines = filtered.isEmpty
                ? Array(ocrLines.prefix(4))
                : Array(filtered.prefix(4))
        }

        var sections: [String] = []
        if let appLabel {
            sections.append("Active app: \(appLabel).")
        } else {
            sections.append("On-device screen summary for \"\(prompt)\":")
        }

        if !matchingElements.isEmpty {
            sections.append("Visible UI controls: \(matchingElements.joined(separator: ", ")).")
        }

        if !matchingOCRLines.isEmpty {
            sections.append("On-screen text: \(matchingOCRLines.joined(separator: " | ")).")
        }

        if matchingElements.isEmpty && matchingOCRLines.isEmpty {
            sections.append("No matching on-screen text or accessibility controls were captured for \"\(prompt)\".")
        }

        return sections.joined(separator: " ")
    }

    private static func resolvedAppLabel(from context: OfflineScreenContext) -> String? {
        let trimmedName = context.frontmostAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedBundle = context.frontmostBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedName.isEmpty && !trimmedBundle.isEmpty && trimmedName != trimmedBundle {
            return "\(trimmedName) (\(trimmedBundle))"
        }
        if !trimmedName.isEmpty {
            return trimmedName
        }
        if !trimmedBundle.isEmpty {
            return trimmedBundle
        }
        return nil
    }

    private static func formatAXElement(_ element: AXElementBounds) -> String? {
        let role = element.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateLabels = [element.title, element.description, element.value]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let primaryLabel = candidateLabels.first {
            return "\(role.isEmpty ? "Element" : role): \(primaryLabel)"
        }
        guard !role.isEmpty else {
            return nil
        }
        return role
    }

    private static func extractKeywords(from prompt: String) -> [String] {
        let stopWords: Set<String> = [
            "what", "where", "when", "which", "who", "whom", "whose", "why", "how",
            "the", "and", "for", "with", "that", "this", "from", "into", "onto",
            "are", "was", "were", "can", "could", "should", "would", "will", "does",
            "did", "has", "have", "had", "you", "your", "screen", "current", "currently",
            "show", "showing", "tell", "about", "please", "help", "find", "see", "look"
        ]

        let tokens = prompt
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }

        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }
}
