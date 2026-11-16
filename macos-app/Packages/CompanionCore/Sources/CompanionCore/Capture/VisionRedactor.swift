import CoreGraphics
import CoreML
import Foundation
import Vision

/// Immutable thread-safe container for precompiled sensitive-text regular expressions.
private final class CompiledRegexList: @unchecked Sendable {
    let expressions: [NSRegularExpression]

    init(patterns: [String]) {
        self.expressions = patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [])
        }
    }
}

/// Result of running on-device Vision OCR redaction on a captured frame.
public struct RedactionResult: Sendable {
    public let image: CGImage
    public let redactedRegionCount: Int
    public let recognizedLineCount: Int

    public init(image: CGImage, redactedRegionCount: Int, recognizedLineCount: Int) {
        self.image = image
        self.redactedRegionCount = redactedRegionCount
        self.recognizedLineCount = recognizedLineCount
    }
}

/// Off-main-actor Apple Vision OCR redactor that masks sensitive text before frames leave the Mac.
public actor VisionRedactor {
    /// Built-in regex patterns matching API keys, auth tokens, passwords, cards, and SSNs.
    public static let defaultPatterns: [String] = [
        // Google / Gemini API keys
        #"AIza[0-9A-Za-z_\-]{20,}"#,
        // OpenAI / Anthropic / Stripe secret & project keys
        #"(?:sk|pk|rk)-(?:proj-|live-|test-|ant-)?[0-9A-Za-z_\-]{16,}"#,
        // GitHub, AWS, Slack, and Google OAuth tokens
        #"(?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{20,}"#,
        #"github_pat_[0-9A-Za-z_]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"xox[baprs]-[0-9A-Za-z\-]{10,}"#,
        #"ya29\.[0-9A-Za-z_\-]{12,}"#,
        // Bearer tokens & labeled secret assignments
        #"(?i)bearer\s+[A-Za-z0-9\._\-+/=]{8,}"#,
        #"(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret[_-]?key|client[_-]?secret|private[_-]?key|authorization)\s*[:=]\s*[^\s,;]{4,}"#,
        // Labeled password / passcode values
        #"(?i)(?:password|passwd|passphrase|passcode|master\s+key)\s*[:=]\s*\S+"#,
        // Credit card numbers (16-digit grouped & 15-digit Amex)
        #"\b(?:\d{4}[ \-]?){3}\d{4}\b"#,
        #"\b3[47]\d{2}[ \-]?\d{6}[ \-]?\d{5}\b"#,
        // US Social Security Numbers
        #"\b\d{3}-\d{2}-\d{4}\b"#,
    ]

    public nonisolated let patterns: [String]
    public nonisolated let recognitionLevel: VNRequestTextRecognitionLevel
    public nonisolated let preferCPUOnly: Bool
    private let compiledRegexes: CompiledRegexList

    public init(
        customPatterns: [String] = [],
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        preferCPUOnly: Bool = false
    ) {
        let allPatterns = Self.defaultPatterns + customPatterns.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.patterns = allPatterns
        self.recognitionLevel = recognitionLevel
        self.preferCPUOnly = preferCPUOnly
        self.compiledRegexes = CompiledRegexList(patterns: allPatterns)
    }

    /// Pure synchronous helper checking whether `text` matches any configured sensitive pattern.
    nonisolated public func containsSensitiveText(_ text: String) -> Bool {
        !sensitiveRanges(in: text).isEmpty
    }

    /// Returns all character ranges in `text` matching any configured sensitive pattern.
    nonisolated public func sensitiveRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var ranges: [Range<String.Index>] = []

        for regex in compiledRegexes.expressions {
            let matches = regex.matches(in: text, options: [], range: fullRange)
            for match in matches {
                if let swiftRange = Range(match.range, in: text) {
                    ranges.append(swiftRange)
                }
            }
        }
        return ranges
    }

    /// Runs Vision OCR off `@MainActor` and paints solid black masks over detected sensitive text.
    public func redact(image: CGImage) async -> CGImage {
        await redactWithDetails(image: image).image
    }

    /// Runs Vision OCR off `@MainActor`, returning the masked `CGImage` along with detection counts.
    public func redactWithDetails(image: CGImage) async -> RedactionResult {
        let level = recognitionLevel
        let cpuOnly = preferCPUOnly
        let regexList = compiledRegexes

        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            if cpuOnly,
               let cpuDevice = MLComputeDevice.allComputeDevices.first(where: { device in
                   if case .cpu = device { return true }
                   return false
               }) {
                request.setComputeDevice(cpuDevice, for: .main)
            }
            // Disable language correction so API keys and tokens are not rewritten into words.
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return RedactionResult(image: image, redactedRegionCount: 0, recognizedLineCount: 0)
            }

            let observations = request.results ?? []
            var normalizedBoxes: [CGRect] = []

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let ranges = Self.matchingRanges(in: text, using: regexList.expressions)
                guard !ranges.isEmpty else { continue }

                var addedSubBox = false
                for range in ranges {
                    if let subBox = try? candidate.boundingBox(for: range)?.boundingBox {
                        normalizedBoxes.append(subBox)
                        addedSubBox = true
                    }
                }
                if !addedSubBox {
                    normalizedBoxes.append(observation.boundingBox)
                }
            }

            guard !normalizedBoxes.isEmpty else {
                return RedactionResult(
                    image: image,
                    redactedRegionCount: 0,
                    recognizedLineCount: observations.count
                )
            }

            let masked = Self.applyBlackMasks(to: image, normalizedBoxes: normalizedBoxes)
            return RedactionResult(
                image: masked,
                redactedRegionCount: normalizedBoxes.count,
                recognizedLineCount: observations.count
            )
        }.value
    }

    private nonisolated static func matchingRanges(
        in text: String,
        using expressions: [NSRegularExpression]
    ) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var ranges: [Range<String.Index>] = []

        for regex in expressions {
            for match in regex.matches(in: text, options: [], range: fullRange) {
                if let range = Range(match.range, in: text) {
                    ranges.append(range)
                }
            }
        }
        return ranges
    }

    private nonisolated static func applyBlackMasks(
        to image: CGImage,
        normalizedBoxes: [CGRect]
    ) -> CGImage {
        let width = image.width
        let height = image.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) ?? CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }

        context.draw(image, in: bounds)
        context.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        for normalizedBox in normalizedBoxes {
            // Both Vision normalized coordinates and CGContext use bottom-left origin.
            let pixelRect = VNImageRectForNormalizedRect(normalizedBox, width, height)
            let paddedRect = pixelRect.insetBy(dx: -4, dy: -4).intersection(bounds)
            if !paddedRect.isNull && paddedRect.width > 0 && paddedRect.height > 0 {
                context.fill(paddedRect)
            }
        }

        return context.makeImage() ?? image
    }
}
