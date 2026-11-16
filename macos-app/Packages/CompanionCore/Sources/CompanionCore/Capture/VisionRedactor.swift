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
    public let semanticRedactedLineCount: Int
    public let sanitizedOCRText: String

    public init(
        image: CGImage,
        redactedRegionCount: Int,
        recognizedLineCount: Int,
        semanticRedactedLineCount: Int = 0,
        sanitizedOCRText: String = ""
    ) {
        self.image = image
        self.redactedRegionCount = redactedRegionCount
        self.recognizedLineCount = recognizedLineCount
        self.semanticRedactedLineCount = semanticRedactedLineCount
        self.sanitizedOCRText = sanitizedOCRText
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
    private var semanticClassifier: (any SemanticPIIClassifying)?
    private var semanticPrivacyEnabled: Bool

    public init(
        customPatterns: [String] = [],
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        preferCPUOnly: Bool = false,
        semanticClassifier: (any SemanticPIIClassifying)? = nil,
        semanticPrivacyEnabled: Bool = false
    ) {
        let allPatterns = Self.defaultPatterns + customPatterns.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.patterns = allPatterns
        self.recognitionLevel = recognitionLevel
        self.preferCPUOnly = preferCPUOnly
        self.compiledRegexes = CompiledRegexList(patterns: allPatterns)
        self.semanticClassifier = semanticClassifier ?? (semanticPrivacyEnabled ? HeuristicSemanticPIIClassifier() : nil)
        self.semanticPrivacyEnabled = semanticPrivacyEnabled
    }

    /// Updates semantic privacy classification state and optionally replaces the semantic classifier.
    public func setSemanticPrivacy(
        enabled: Bool,
        classifier: (any SemanticPIIClassifying)? = nil
    ) {
        self.semanticPrivacyEnabled = enabled
        if let classifier {
            self.semanticClassifier = classifier
        } else if enabled && self.semanticClassifier == nil {
            self.semanticClassifier = HeuristicSemanticPIIClassifier()
        }
    }

    /// Pure synchronous helper checking whether `text` matches any configured sensitive pattern.
    nonisolated public func containsSensitiveText(_ text: String) -> Bool {
        !sensitiveRanges(in: text).isEmpty
    }

    /// Returns all character ranges in `text` matching any configured sensitive pattern.
    nonisolated public func sensitiveRanges(in text: String) -> [Range<String.Index>] {
        Self.matchingRanges(in: text, using: compiledRegexes.expressions)
    }

    /// Replaces all regex-matched sensitive ranges in `text` with `"[REDACTED]"` from end to start.
    nonisolated public func redactSensitiveText(_ text: String) -> String {
        let ranges = Self.mergedRanges(sensitiveRanges(in: text))
        guard !ranges.isEmpty else { return text }
        var redacted = text
        for range in ranges.reversed() {
            redacted.replaceSubrange(range, with: "[REDACTED]")
        }
        return redacted
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
        let isSemanticEnabled = semanticPrivacyEnabled
        let classifier = semanticClassifier

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
                // Fail closed on Vision OCR error by masking the full frame bounds.
                let fullBoundsMask = [CGRect(x: 0, y: 0, width: 1, height: 1)]
                let masked = Self.applyBlackMasks(to: image, normalizedBoxes: fullBoundsMask)
                return RedactionResult(
                    image: masked,
                    redactedRegionCount: 1,
                    recognizedLineCount: 0,
                    semanticRedactedLineCount: 0,
                    sanitizedOCRText: ""
                )
            }

            let observations = request.results ?? []
            var normalizedBoxes: [CGRect] = []

            struct RecognizedLine {
                let observation: VNRecognizedTextObservation
                let text: String
                let regexMatched: Bool
            }

            var recognizedLines: [RecognizedLine] = []
            recognizedLines.reserveCapacity(observations.count)

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let ranges = Self.matchingRanges(in: text, using: regexList.expressions)
                guard !ranges.isEmpty else {
                    recognizedLines.append(
                        RecognizedLine(observation: observation, text: text, regexMatched: false)
                    )
                    continue
                }

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
                recognizedLines.append(
                    RecognizedLine(observation: observation, text: text, regexMatched: true)
                )
            }

            var semanticFlaggedLineIndices: Set<Int> = []
            var semanticRedactedLineCount = 0

            if isSemanticEnabled, let classifier {
                let unmatchedLineIndices = recognizedLines.indices.filter { !recognizedLines[$0].regexMatched }
                if !unmatchedLineIndices.isEmpty {
                    let unmatchedTexts = unmatchedLineIndices.map { recognizedLines[$0].text }
                    let flaggedUnmatched = await Self.classifyWithTimeout(
                        lines: unmatchedTexts,
                        using: classifier,
                        timeoutNanoseconds: 400_000_000
                    )
                    for unmatchedIndex in flaggedUnmatched.sorted() {
                        guard unmatchedIndex >= 0 && unmatchedIndex < unmatchedLineIndices.count else {
                            continue
                        }
                        let recognizedIndex = unmatchedLineIndices[unmatchedIndex]
                        semanticFlaggedLineIndices.insert(recognizedIndex)
                        normalizedBoxes.append(recognizedLines[recognizedIndex].observation.boundingBox)
                        semanticRedactedLineCount += 1
                    }
                }
            }

            let sanitizedOCRText = recognizedLines.enumerated().map { index, line in
                if line.regexMatched || semanticFlaggedLineIndices.contains(index) {
                    return "[REDACTED]"
                }
                return line.text
            }.joined(separator: "\n")

            guard !normalizedBoxes.isEmpty else {
                return RedactionResult(
                    image: image,
                    redactedRegionCount: 0,
                    recognizedLineCount: observations.count,
                    semanticRedactedLineCount: 0,
                    sanitizedOCRText: sanitizedOCRText
                )
            }

            let masked = Self.applyBlackMasks(to: image, normalizedBoxes: normalizedBoxes)
            return RedactionResult(
                image: masked,
                redactedRegionCount: normalizedBoxes.count,
                recognizedLineCount: observations.count,
                semanticRedactedLineCount: semanticRedactedLineCount,
                sanitizedOCRText: sanitizedOCRText
            )
        }.value
    }

    private nonisolated static func classifyWithTimeout(
        lines: [String],
        using classifier: any SemanticPIIClassifying,
        timeoutNanoseconds: UInt64
    ) async -> Set<Int> {
        await withTaskGroup(of: Set<Int>?.self) { group in
            group.addTask {
                try? await classifier.classifySensitiveLineIndices(lines)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult ?? []
        }
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

    private nonisolated static func mergedRanges(
        _ ranges: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBound < $1.upperBound
        }
        var merged: [Range<String.Index>] = [sorted[0]]
        for current in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if current.lowerBound <= last.upperBound {
                let newUpper = max(last.upperBound, current.upperBound)
                merged[merged.count - 1] = last.lowerBound..<newUpper
            } else {
                merged.append(current)
            }
        }
        return merged
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
