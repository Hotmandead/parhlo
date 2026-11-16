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

        utteranceGeneration &+= 1
        delegateProxy.setGeneration(utteranceGeneration)

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Immediately halts any active or queued speech synthesis.
    public func stopImmediately() {
        utteranceGeneration &+= 1
        delegateProxy.setGeneration(utteranceGeneration)
        _ = synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

private final class SpeechSynthesizerDelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct State {
        var generation: UInt64 = 0
        var onDidFinishOrCancel: (@Sendable (UInt64) -> Void)?
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func setGeneration(_ generation: UInt64) {
        lock.withLock { state in
            state.generation = generation
        }
    }

    func setCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock { state in
            state.onDidFinishOrCancel = handler
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        notifyCompletion()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        notifyCompletion()
    }

    nonisolated private func notifyCompletion() {
        let (generation, handler) = lock.withLock { state in
            (state.generation, state.onDidFinishOrCancel)
        }
        handler?(generation)
    }
}
