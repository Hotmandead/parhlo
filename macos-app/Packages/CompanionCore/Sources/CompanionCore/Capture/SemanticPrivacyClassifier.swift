import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Protocol for asynchronous semantic PII and contextual secret classification over OCR lines.
public protocol SemanticPIIClassifying: Sendable {
    /// Returns the zero-based indices of `lines` that contain semantically sensitive PII or secrets.
    func classifySensitiveLineIndices(_ lines: [String]) async throws -> Set<Int>
}

/// Bounded LRU cache mapping normalized OCR lines to their semantic sensitivity classification.
public actor SemanticPIICache {
    public let capacity: Int
    private var storage: [String: Bool] = [:]
    private var accessOrder: [String] = []

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// Normalizes an OCR line for cache lookup by trimming and collapsing whitespace runs.
    public nonisolated static func normalize(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    public func value(for line: String) -> Bool? {
        let key = Self.normalize(line)
        guard !key.isEmpty, let result = storage[key] else {
            return nil
        }
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
        return result
    }

    public func get(_ line: String) -> Bool? {
        value(for: line)
    }

    public func insert(_ isSensitive: Bool, for line: String) {
        let key = Self.normalize(line)
        guard !key.isEmpty else { return }

        if storage[key] != nil {
            storage[key] = isSensitive
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
            }
            accessOrder.append(key)
            return
        }

        if storage.count >= capacity, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }

        storage[key] = isSensitive
        accessOrder.append(key)
    }

    public func set(_ isSensitive: Bool, for line: String) {
        insert(isSensitive, for: line)
    }

    public func clear() {
        storage.removeAll()
        accessOrder.removeAll()
    }

    public var count: Int {
        storage.count
    }
}

/// Immutable container for precompiled semantic heuristic regular expressions.
private final class CompiledSemanticRegexList: @unchecked Sendable {
    let expressions: [NSRegularExpression]

    init(patterns: [String]) {
        self.expressions = patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [])
        }
    }
}

/// Fast on-device semantic PII classifier combining context-sensitive heuristics, `SemanticPIICache`,
/// and optional Apple `FoundationModels` fallback when available on macOS 26+.
public actor HeuristicSemanticPIIClassifier: SemanticPIIClassifying {
    private static let semanticPatterns: [String] = [
        // Contextual PINs, OTPs, 2FA/MFA codes, CVV/CVC, and verification codes
        #"(?i)\b(?:pin(?:\s+code|\s+number)?|passcode|otp|one[- ]time\s+(?:code|password|pin)|verification\s+code|security\s+code|auth(?:entication)?\s+code|2fa(?:\s+code)?|mfa(?:\s+code)?|cvv2?|cvc2?|backup\s+code)\b[^\n\r\d]{0,25}\b\d{3,8}\b"#,
        #"(?i)\b\d{4,8}\b\s+(?:is\s+(?:your|my|the)\s+)?(?:pin(?:\s+code)?|passcode|otp|verification\s+code|security\s+code|2fa\s+code)\b"#,
        // Natural-language password, passphrase, or secret disclosures without colon/equals
        #"(?i)\b(?:password|passwd|passphrase|secret(?:\s+key|\s+phrase)?|master\s+(?:key|password)|private\s+key|api\s+key|access\s+token|recovery\s+key|vault\s+(?:key|password))\s+(?:is|was|equals|set\s+to)\s+\S+"#,
        #"(?i)\bmy\s+(?:password|passphrase|pin|secret\s+key|ssn|social\s+security(?:\s+number)?|routing\s+number|account\s+number|seed\s+phrase|recovery\s+phrase)\b"#,
        // Recovery phrases, seed phrases, and wallet mnemonics
        #"(?i)\b(?:recovery\s+phrase|seed\s+phrase|secret\s+recovery\s+phrase|mnemonic(?:\s+phrase)?|backup\s+phrase|wallet\s+seed|12[- ]word\s+phrase|24[- ]word\s+phrase)\b"#,
        // Numbered mnemonic word lists (e.g. "1. abandon 2. ability 3. able 4. about")
        #"(?:\b\d{1,2}[\.\)]\s*[a-z]{3,10}\s*){4,}"#,
        // Bank routing, account, IBAN, SWIFT/BIC, SSN, Tax ID, Passport, and Driver's License context
        #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#,
        #"(?i)\b(?:routing\s*(?:number|no\.?|#)?|account\s*(?:number|no\.?|#)|acct\s*(?:number|no\.?|#)?|bank\s+account|iban|swift(?:\s+code)?|bic(?:\s+code)?|ssn|social\s+security(?:\s+number)?|tax\s*id|ein|itin|passport(?:\s+number|\s+no\.?|\s+#)?|driver'?s?\s+licen[sc]e)\b[^\n\r\dA-Z]{0,20}[A-Z0-9][A-Z0-9\- ]{3,}"#,
        // PEM / OpenSSH / PGP private key blocks and connection URIs with embedded credentials
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?:\s+BLOCK)?-----"#,
        #"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|rediss|amqp|amqps)://[^/\s:@]+:[^/\s@]+@[^\s]+"#,
        #"(?i)\b(?:aws_secret_access_key|secret_access_key|x-api-key)\b\s*[:=]?\s*\S+"#,
    ]

    private static let compiledRegexes = CompiledSemanticRegexList(patterns: semanticPatterns)

    public let cache: SemanticPIICache
    public let useFoundationModelsIfAvailable: Bool

    public init(
        cache: SemanticPIICache = SemanticPIICache(),
        useFoundationModelsIfAvailable: Bool = false
    ) {
        self.cache = cache
        self.useFoundationModelsIfAvailable = useFoundationModelsIfAvailable
    }

    public func classifySensitiveLineIndices(_ lines: [String]) async throws -> Set<Int> {
        var sensitiveIndices: Set<Int> = []
        var uncachedIndices: [Int] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let cached = await cache.value(for: trimmed) {
                if cached {
                    sensitiveIndices.insert(index)
                }
                continue
            }

            if Self.isSemanticallySensitive(trimmed) {
                await cache.insert(true, for: trimmed)
                sensitiveIndices.insert(index)
            } else {
                uncachedIndices.append(index)
            }
        }

        guard !uncachedIndices.isEmpty else {
            return sensitiveIndices
        }

        if useFoundationModelsIfAvailable {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if let modelIndices = try? await classifyWithFoundationModels(
                    lines: lines,
                    candidateIndices: uncachedIndices
                ) {
                    for index in uncachedIndices {
                        let isSensitive = modelIndices.contains(index)
                        await cache.insert(isSensitive, for: lines[index])
                        if isSensitive {
                            sensitiveIndices.insert(index)
                        }
                    }
                    return sensitiveIndices
                }
            }
            #endif
        }

        for index in uncachedIndices {
            await cache.insert(false, for: lines[index])
        }

        return sensitiveIndices
    }

    /// Synchronous semantic sensitivity check for a single OCR line.
    public nonisolated static func isSemanticallySensitive(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for regex in compiledRegexes.expressions {
            if regex.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
                return true
            }
        }

        if looksLikeMnemonicSeedLine(trimmed) {
            return true
        }

        return false
    }

    /// Detects unnumbered 12/15/18/21/24-word (or 6+ word) strictly lowercase mnemonic seed lines.
    private nonisolated static func looksLikeMnemonicSeedLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 6 && tokens.count <= 24 else { return false }

        let commonStopWords: Set<Substring> = [
            "the", "and", "for", "that", "this", "with", "from", "your", "have", "are", "was", "were"
        ]
        var stopWordCount = 0

        for token in tokens {
            guard token.count >= 3 && token.count <= 8 else { return false }
            for scalar in token.unicodeScalars {
                guard scalar.value >= 97 && scalar.value <= 122 else { return false }
            }
            if commonStopWords.contains(token) {
                stopWordCount += 1
            }
        }

        return stopWordCount <= 1
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func classifyWithFoundationModels(
        lines: [String],
        candidateIndices: [Int]
    ) async throws -> Set<Int> {
        guard SystemLanguageModel.default.isAvailable else {
            return []
        }

        let numberedPrompt = candidateIndices.map { idx in
            "\(idx): \(lines[idx])"
        }.joined(separator: "\n")

        let session = LanguageModelSession(
            instructions: """
            You are an on-device privacy classifier. Identify line numbers that contain sensitive PII, \
            secrets, passwords, PINs, recovery phrases, bank/routing/IBAN numbers, or private keys. \
            Reply ONLY with comma-separated line numbers (e.g. 0,3) or NONE.
            """
        )
        let response = try await session.respond(to: numberedPrompt)
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.uppercased() != "NONE" else {
            return []
        }

        let validCandidates = Set(candidateIndices)
        var flagged: Set<Int> = []
        for part in content.components(separatedBy: CharacterSet(charactersIn: ", \n\t")) {
            if let idx = Int(part.trimmingCharacters(in: .whitespacesAndNewlines)),
               validCandidates.contains(idx) {
                flagged.insert(idx)
            }
        }
        return flagged
    }
    #endif
}

/// Default semantic PII classifier actor that enables `FoundationModels` when available on macOS 26+
/// and falls back to context-sensitive heuristics and `SemanticPIICache`.
public typealias DefaultSemanticPIIClassifier = HeuristicSemanticPIIClassifier
