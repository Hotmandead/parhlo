@preconcurrency import AVFoundation
import Foundation
import Observation
import os

/// Speaks offline assistant answers using macOS `AVSpeechSynthesizer` with instant barge-in cancellation.
@MainActor
@Observable
public final class OfflineSpeechManager {
    public private(set) var isSpeaking: Bool = false
    public var isEnabled: Bool = true

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let delegateProxy = SpeechSynthesizerDelegateProxy()
    @ObservationIgnored private var utteranceGeneration: UInt64 = 0

    public init() {
        delegateProxy.setCompletionHandler { [weak self] generation in
            Task { @MainActor [weak self] in
                guard let self, self.utteranceGeneration == generation else { return }
                self.isSpeaking = false
            }
        }
        synthesizer.delegate = delegateProxy
    }

    /// Speaks the provided text using the default system voice unless muted, disabled, or empty.
    public func speak(_ text: String, muted: Bool = false) {
        stopImmediately()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !muted, isEnabled, !trimmed.isEmpty else {
            return
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        utteranceGeneration &+= 1
        delegateProxy.setActiveUtterance(
            id: ObjectIdentifier(utterance),
            generation: utteranceGeneration
        )

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Immediately halts any active or queued speech synthesis.
    public func stopImmediately() {
        utteranceGeneration &+= 1
        delegateProxy.clearActiveUtterance(generation: utteranceGeneration)
        _ = synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

private final class SpeechSynthesizerDelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct State {
        var generation: UInt64 = 0
        var activeUtteranceID: ObjectIdentifier?
        var onDidFinishOrCancel: (@Sendable (UInt64) -> Void)?
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func setActiveUtterance(id: ObjectIdentifier, generation: UInt64) {
        lock.withLock { state in
            state.activeUtteranceID = id
            state.generation = generation
        }
    }

    func clearActiveUtterance(generation: UInt64) {
        lock.withLock { state in
            state.activeUtteranceID = nil
            state.generation = generation
        }
    }

    func setCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock { state in
            state.onDidFinishOrCancel = handler
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        notifyCompletion(for: ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        notifyCompletion(for: ObjectIdentifier(utterance))
    }

    nonisolated private func notifyCompletion(for utteranceID: ObjectIdentifier) {
        let match: (UInt64, (@Sendable (UInt64) -> Void)?) = lock.withLock { state in
            guard state.activeUtteranceID == utteranceID else {
                return (0, nil)
            }
            state.activeUtteranceID = nil
            return (state.generation, state.onDidFinishOrCancel)
        }
        if let handler = match.1 {
            handler(match.0)
        }
    }
}
