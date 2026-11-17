import AppKit
import Foundation
import Observation

/// Activation style for the global `Control+Option` (`⌃⌥`) voice trigger.
public enum HotkeyActivationMode: String, CaseIterable, Sendable, Equatable {
    case smartTapOrHold = "smart"
    case tapToToggle = "toggle"
    case holdToSpeak = "hold"

    public var displayTitle: String {
        switch self {
        case .smartTapOrHold: "Smart (Tap to Toggle / Hold to Speak)"
        case .tapToToggle: "Tap to Toggle"
        case .holdToSpeak: "Hold to Speak"
        }
    }
}

/// Pure, testable state machine detecting `Control+Option` (`⌃⌥`) modifier chords.
public struct ControlOptionChordDetector: Sendable, Equatable {
    public var mode: HotkeyActivationMode
    public var holdThresholdSeconds: TimeInterval

    private(set) var isChordActive: Bool = false
    private(set) var chordPressedAt: Date?
    private(set) var isSessionActive: Bool = false
    private var sawDisqualifyingModifier: Bool = false
    private var sessionStateBeforeChord: Bool = false

    public init(
        mode: HotkeyActivationMode = .smartTapOrHold,
        holdThresholdSeconds: TimeInterval = 0.35
    ) {
        self.mode = mode
        self.holdThresholdSeconds = max(0.1, holdThresholdSeconds)
    }

    /// Evaluates whether `Control+Option` are held without `Command` or `Shift`.
    public static func isControlOptionChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.control, .option, .command, .shift])
        return relevant == [.control, .option]
    }

    /// Processes a modifier change and returns `true` (start), `false` (stop), or `nil` (no change).
    public mutating func process(flags: NSEvent.ModifierFlags, now: Date = Date()) -> Bool? {
        let relevant = flags.intersection([.control, .option, .command, .shift])
        let hasDisqualifying = !relevant.intersection([.command, .shift]).isEmpty
        if hasDisqualifying {
            sawDisqualifyingModifier = true
        } else if relevant.isEmpty {
            sawDisqualifyingModifier = false
        }

        let chordDown = !sawDisqualifyingModifier && Self.isControlOptionChord(flags)
        guard chordDown != isChordActive else { return nil }

        isChordActive = chordDown

        if chordDown {
            chordPressedAt = now
            sessionStateBeforeChord = isSessionActive
            switch mode {
            case .holdToSpeak:
                if !isSessionActive {
                    isSessionActive = true
                    return true
                }
                return nil
            case .tapToToggle, .smartTapOrHold:
                isSessionActive.toggle()
                return isSessionActive
            }
        } else {
            let heldDuration = chordPressedAt.map { now.timeIntervalSince($0) } ?? 0
            chordPressedAt = nil

            if hasDisqualifying && heldDuration < 0.25 && !sessionStateBeforeChord && isSessionActive {
                isSessionActive = false
                return false
            }

            switch mode {
            case .tapToToggle:
                return nil
            case .holdToSpeak:
                if isSessionActive {
                    isSessionActive = false
                    return false
                }
                return nil
            case .smartTapOrHold:
                if isSessionActive && heldDuration >= holdThresholdSeconds {
                    isSessionActive = false
                    return false
                }
                return nil
            }
        }
    }

    /// Synchronizes external session state changes (e.g. menu bar Start/Stop) with the detector.
    public mutating func syncSessionActive(_ active: Bool) {
        isSessionActive = active
    }
}

private final class MonitorTokenBox: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

/// Registers global and local macOS modifier monitors for `Control+Option` (`⌃⌥`) voice activation.
@MainActor
@Observable
public final class GlobalHotkeyManager {
    public var mode: HotkeyActivationMode {
        didSet { detector.mode = mode }
    }
    public private(set) var isMonitoring: Bool = false
    public private(set) var isGlobalMonitorActive: Bool = false

    @ObservationIgnored public var onSessionRequested: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private var detector = ControlOptionChordDetector()
    @ObservationIgnored private nonisolated(unsafe) var globalMonitor: MonitorTokenBox?
    @ObservationIgnored private nonisolated(unsafe) var localMonitor: MonitorTokenBox?

    public init(mode: HotkeyActivationMode = .smartTapOrHold) {
        self.mode = mode
        self.detector.mode = mode
    }

    deinit {
        let global = globalMonitor
        let local = localMonitor
        globalMonitor = nil
        localMonitor = nil
        if global != nil || local != nil {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if let global { NSEvent.removeMonitor(global.value) }
                    if let local { NSEvent.removeMonitor(local.value) }
                }
            } else {
                Task { @MainActor in
                    if let global { NSEvent.removeMonitor(global.value) }
                    if let local { NSEvent.removeMonitor(local.value) }
                }
            }
        }
    }

    /// Installs global + local `.flagsChanged` monitors so `Control+Option` works across any app.
    public func startMonitoring() {
        if globalMonitor == nil {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let flags = event.modifierFlags
                let now = Date()
                Task { @MainActor [weak self] in
                    self?.handleModifierFlags(flags, now: now)
                }
            }
            if let monitor {
                globalMonitor = MonitorTokenBox(monitor)
            }
        }

        if localMonitor == nil {
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let flags = event.modifierFlags
                let now = Date()
                Task { @MainActor [weak self] in
                    self?.handleModifierFlags(flags, now: now)
                }
                return event
            }
            if let monitor {
                localMonitor = MonitorTokenBox(monitor)
            }
        }

        isGlobalMonitorActive = (globalMonitor != nil)
        isMonitoring = (globalMonitor != nil || localMonitor != nil)
    }

    /// Removes active modifier monitors.
    public func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor.value)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor.value)
            self.localMonitor = nil
        }
        isGlobalMonitorActive = false
        isMonitoring = false
    }

    public func syncSessionActive(_ active: Bool) {
        detector.syncSessionActive(active)
    }

    public func handleModifierFlags(_ flags: NSEvent.ModifierFlags, now: Date = Date()) {
        if let requestedActive = detector.process(flags: flags, now: now) {
            onSessionRequested?(requestedActive)
        }
    }
}
