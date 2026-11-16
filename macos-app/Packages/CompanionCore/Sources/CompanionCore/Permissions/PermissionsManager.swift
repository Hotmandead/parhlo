import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import Speech

/// Authorization status for macOS TCC permissions required by Parhlo.
public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined

    public var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not Requested"
        }
    }
}

/// Manages Screen Recording, Accessibility, and Microphone TCC authorization states.
@MainActor
@Observable
public final class PermissionsManager {
    public private(set) var screenRecording: PermissionStatus = .notDetermined
    public private(set) var accessibility: PermissionStatus = .notDetermined
    public private(set) var microphone: PermissionStatus = .notDetermined
    public private(set) var speechRecognition: PermissionStatus = .notDetermined

    public var allGranted: Bool {
        screenRecording == .granted
            && accessibility == .granted
            && microphone == .granted
            && speechRecognition == .granted
    }

    public init() {
        refresh()
    }

    /// Re-reads current TCC status for Screen Recording, Accessibility, Microphone, and Speech Recognition.
    public func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .denied, .restricted:
            microphone = .denied
        case .notDetermined:
            microphone = .notDetermined
        @unknown default:
            microphone = .notDetermined
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechRecognition = .granted
        case .denied, .restricted:
            speechRecognition = .denied
        case .notDetermined:
            speechRecognition = .notDetermined
        @unknown default:
            speechRecognition = .notDetermined
        }
    }

    /// Requests Speech Recognition authorization for live voice-to-text transcription.
    public func requestSpeechRecognition() async {
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        refresh()
    }

    /// Prompts macOS Screen Recording permission dialog.
    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    /// Prompts macOS Accessibility trust dialog for `AXUIElement` tree inspection.
    public func requestAccessibility() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Requests Microphone authorization for 16 kHz bidirectional voice capture.
    public func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Opens the matching Privacy & Security pane in macOS System Settings.
    public func openSystemSettings(for pane: PrivacyPane) {
        guard let url = pane.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    public enum PrivacyPane: Sendable {
        case screenCapture
        case accessibility
        case microphone
        case speechRecognition

        public var settingsURL: URL? {
            switch self {
            case .screenCapture:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speechRecognition:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            }
        }
    }
}
