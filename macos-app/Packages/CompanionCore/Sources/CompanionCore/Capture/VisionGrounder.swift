import CoreGraphics
import CoreML
import Foundation
import Vision

/// Off-main-actor Vision shape detector and structured document grounding engine (Phase 5).
public actor VisionGrounder {
    public init() {}

    /// Detects rectangular UI regions when the Accessibility hierarchy is sparse or unavailable,
    /// converting Vision's bottom-left normalized coordinates into top-left screen pixel bounds.
    public func detectRectangles(
        in image: CGImage,
        screenSize: CGSize,
        maxCount: Int = 30
    ) async -> [DetectedRectBounds] {
        guard maxCount > 0 else { return [] }
        let effectiveWidth = screenSize.width > 0 ? screenSize.width : CGFloat(image.width)
        let effectiveHeight = screenSize.height > 0 ? screenSize.height : CGFloat(image.height)
        guard effectiveWidth > 0, effectiveHeight > 0 else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectRectanglesRequest()
            request.minimumAspectRatio = 0.15
            request.maximumAspectRatio = 6.0
            request.quadratureTolerance = 15.0
            request.minimumSize = 0.02
            request.minimumConfidence = 0.6
            request.maximumObservations = max(1, min(40, maxCount))
            if let cpuDevice = MLComputeDevice.allComputeDevices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) {
                request.setComputeDevice(cpuDevice, for: .main)
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }

            let observations = request.results ?? []
            let maxAllowedArea = 0.90 * effectiveWidth * effectiveHeight
            var candidates: [DetectedRectBounds] = []
            candidates.reserveCapacity(observations.count)

            for observation in observations {
                let box = observation.boundingBox
                let x = Int(box.minX * effectiveWidth)
                let y = Int((1.0 - box.maxY) * effectiveHeight)
                let w = Int(box.width * effectiveWidth)
                let h = Int(box.height * effectiveHeight)

                guard w >= 12, h >= 12 else { continue }
                let area = CGFloat(w * h)
                guard area <= maxAllowedArea else { continue }

                candidates.append(
                    DetectedRectBounds(
                        x: x,
                        y: y,
                        width: w,
                        height: h,
                        confidence: Double(observation.confidence)
                    )
                )
            }

            candidates.sort { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return (lhs.width * lhs.height) < (rhs.width * rhs.height)
            }

            if candidates.count > maxCount {
                return Array(candidates.prefix(maxCount))
            }
            return candidates
        }.value
    }

    /// Extracts structured, privacy-redacted document context from `image` using sanitized OCR lines by default
    /// (avoiding redundant full-frame Vision passes and E5 ANE bundle warnings), or macOS 26
    /// `RecognizeDocumentsRequest` when `useStructuredVisionRequest` is explicitly enabled.
    public func extractDocumentContext(
        from image: CGImage,
        redactor: VisionRedactor,
        fallbackText: String = "",
        maxTotalChars: Int = 4000,
        useStructuredVisionRequest: Bool = false
    ) async -> DocumentContext? {
        let charBudget = max(1, maxTotalChars)

        if !fallbackText.isEmpty && !useStructuredVisionRequest {
            return Self.buildFallbackContext(
                from: fallbackText,
                redactor: redactor,
                maxTotalChars: charBudget
            )
        }

        if useStructuredVisionRequest, #available(macOS 26.0, *) {
            if let structured = await recognizeStructuredDocument(
                from: image,
                redactor: redactor,
                maxTotalChars: charBudget
            ), !structured.paragraphs.isEmpty || !structured.tables.isEmpty {
                return structured
            }
        }

        guard !fallbackText.isEmpty else { return nil }
        return Self.buildFallbackContext(
            from: fallbackText,
            redactor: redactor,
            maxTotalChars: charBudget
        )
    }

    @available(macOS 26.0, *)
    private func recognizeStructuredDocument(
        from image: CGImage,
        redactor: VisionRedactor,
        maxTotalChars: Int
    ) async -> DocumentContext? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = false
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "en-US")]

        let observations: [DocumentObservation]
        do {
            observations = try await request.perform(on: image)
        } catch {
            return nil
        }

        guard let doc = observations.first?.document else { return nil }

        var usedChars = 0
        var truncated = false

        var redactedTitle: String?
        if let rawTitle = doc.title?.transcript {
            let cleanedTitle = Self.cleanAndRedact(rawTitle, redactor: redactor)
            if !cleanedTitle.isEmpty {
                let cappedTitle = Self.capString(
                    cleanedTitle,
                    maxLength: min(300, maxTotalChars),
                    truncated: &truncated
                )
                if !cappedTitle.isEmpty {
                    redactedTitle = cappedTitle
                    usedChars += cappedTitle.count
                }
            }
        }

        let rawParagraphs: [String]
        if !doc.paragraphs.isEmpty {
            rawParagraphs = doc.paragraphs.map(\.transcript)
        } else {
            rawParagraphs = doc.text.lines.map(\.transcript)
        }

        var paragraphs: [String] = []
        for rawParagraph in rawParagraphs {
            let cleaned = Self.cleanAndRedact(rawParagraph, redactor: redactor)
            guard !cleaned.isEmpty else { continue }

            if paragraphs.count >= 12 {
                truncated = true
                break
            }

            let remaining = maxTotalChars - usedChars
            guard remaining > 0 else {
                truncated = true
                break
            }

            let capped = Self.capString(
                cleaned,
                maxLength: min(300, remaining),
                truncated: &truncated
            )
            guard !capped.isEmpty else { continue }
            paragraphs.append(capped)
            usedChars += capped.count
        }

        var tables: [DocumentTableSummary] = []
        for table in doc.tables {
            if tables.count >= 2 {
                truncated = true
                break
            }
            if usedChars >= maxTotalChars {
                truncated = true
                break
            }
            if table.rows.count > 12 {
                truncated = true
            }

            var summarizedRows: [[String]] = []
            for row in table.rows.prefix(12) {
                if usedChars >= maxTotalChars {
                    truncated = true
                    break
                }
                if row.count > 8 {
                    truncated = true
                }

                var rowCells: [String] = []
                for cell in row.prefix(8) {
                    let remaining = maxTotalChars - usedChars
                    guard remaining > 0 else {
                        truncated = true
                        break
                    }
                    let cleanedCell = Self.cleanAndRedact(
                        cell.content.text.transcript,
                        redactor: redactor
                    )
                    let cappedCell = Self.capString(
                        cleanedCell,
                        maxLength: min(300, remaining),
                        truncated: &truncated
                    )
                    rowCells.append(cappedCell)
                    usedChars += cappedCell.count
                }

                if rowCells.contains(where: { !$0.isEmpty }) {
                    summarizedRows.append(rowCells)
                }
            }

            if !summarizedRows.isEmpty {
                tables.append(DocumentTableSummary(rows: summarizedRows))
            }
        }

        guard !paragraphs.isEmpty || !tables.isEmpty else { return nil }
        return DocumentContext(
            title: redactedTitle,
            paragraphs: paragraphs,
            tables: tables,
            truncated: truncated
        )
    }

    nonisolated private static func buildFallbackContext(
        from fallbackText: String,
        redactor: VisionRedactor,
        maxTotalChars: Int
    ) -> DocumentContext? {
        let rawLines = fallbackText.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        var usedChars = 0
        var truncated = false

        for rawLine in rawLines {
            let cleaned = cleanAndRedact(rawLine, redactor: redactor)
            guard !cleaned.isEmpty else { continue }

            if paragraphs.count >= 12 {
                truncated = true
                break
            }

            let remaining = maxTotalChars - usedChars
            guard remaining > 0 else {
                truncated = true
                break
            }

            let capped = capString(
                cleaned,
                maxLength: min(300, remaining),
                truncated: &truncated
            )
            guard !capped.isEmpty else { continue }
            paragraphs.append(capped)
            usedChars += capped.count
        }

        guard !paragraphs.isEmpty else { return nil }
        return DocumentContext(
            title: nil,
            paragraphs: paragraphs,
            tables: [],
            truncated: truncated
        )
    }

    nonisolated private static func cleanAndRedact(
        _ raw: String,
        redactor: VisionRedactor
    ) -> String {
        let redacted = redactor.redactSensitiveText(raw)
        return redacted
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func capString(
        _ text: String,
        maxLength: Int,
        truncated: inout Bool
    ) -> String {
        guard maxLength > 0 else {
            if !text.isEmpty {
                truncated = true
            }
            return ""
        }
        guard text.count > maxLength else {
            return text
        }
        truncated = true
        return String(text.prefix(maxLength))
    }
}
