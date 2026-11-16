import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Errors raised by `CaptureEngine` during on-demand screen and AX capture.
public enum CaptureError: Error, Sendable, Equatable {
    case privacyPaused(bundleID: String?)
    case noDisplayFound
    case jpegEncodingFailed
    case throttled
    case captureFailed(String)
}

private struct DisplayCaptureSnapshot: Sendable {
    let image: CGImage
    let logicalWidth: Int
    let logicalHeight: Int
    let displayBounds: CGRect
}

/// On-demand ScreenCaptureKit + AXUIElement + VisionRedactor pipeline capped at `<= 1 FPS`.
@MainActor
@Observable
public final class CaptureEngine {
    nonisolated public static let defaultJPEGQuality: Double = 0.65
    nonisolated public static let minimumAllowedInterval: TimeInterval = 1.0

    public private(set) var isSessionActive: Bool = false
    public private(set) var lastCaptureDate: Date?

    @ObservationIgnored private let privacyFilter: PrivacyFilter
    @ObservationIgnored private let redactor: VisionRedactor
    @ObservationIgnored private let axInspector: AXInspector
    @ObservationIgnored private let ownBundleID: String
    @ObservationIgnored private let ownPID: pid_t
    @ObservationIgnored private let jpegQuality: Double

    @ObservationIgnored private var captureTask: Task<Void, Never>?

    public init(
        privacyFilter: PrivacyFilter,
        redactor: VisionRedactor = VisionRedactor(),
        axInspector: AXInspector = AXInspector(),
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.parhlo.ScreenCompanionApp",
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        jpegQuality: Double = CaptureEngine.defaultJPEGQuality
    ) {
        self.privacyFilter = privacyFilter
        self.redactor = redactor
        self.axInspector = axInspector
        self.ownBundleID = ownBundleID
        self.ownPID = ownPID
        self.jpegQuality = min(1.0, max(0.1, jpegQuality))
    }

    deinit {
        captureTask?.cancel()
    }

    /// Starts on-demand periodic capture strictly capped at `<= 1 FPS` (`interval >= 1.0`).
    /// Never runs in the background unless explicitly started by an active session.
    public func startSessionCapture(
        interval: TimeInterval = 1.0,
        onFrame: @escaping @Sendable (ScreenContextMessage) async -> Void
    ) {
        stopSessionCapture()

        let effectiveInterval = max(Self.minimumAllowedInterval, interval)
        isSessionActive = true

        captureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSessionActive else { break }

                if !self.privacyFilter.isPaused {
                    do {
                        let message = try await self.captureOnce(respectRateLimit: true)
                        if !Task.isCancelled && self.isSessionActive && !self.privacyFilter.isPaused {
                            await onFrame(message)
                        }
                    } catch CaptureError.privacyPaused, CaptureError.throttled {
                        // Expected while a protected app is active or inside the 1 FPS window.
                    } catch {
                        // Keep the session alive across transient capture failures.
                    }
                }

                try? await Task.sleep(for: .seconds(effectiveInterval))
            }
        }
    }

    /// Stops any active session capture loop immediately.
    public func stopSessionCapture() {
        isSessionActive = false
        captureTask?.cancel()
        captureTask = nil
    }

    /// Captures a single redacted screen + AX snapshot on demand, respecting `PrivacyFilter` and `<= 1 FPS`.
    public func captureOnce(respectRateLimit: Bool = true) async throws -> ScreenContextMessage {
        let frontmost = NSWorkspace.shared.frontmostApplication
        privacyFilter.evaluateFrontmostApplication(
            bundleIdentifier: frontmost?.bundleIdentifier,
            appName: frontmost?.localizedName
        )

        guard !privacyFilter.isPaused else {
            throw CaptureError.privacyPaused(bundleID: privacyFilter.frontmostBundleID)
        }

        let now = Date()
        if respectRateLimit, let lastCaptureDate, now.timeIntervalSince(lastCaptureDate) < Self.minimumAllowedInterval {
            throw CaptureError.throttled
        }

        let excludedIDs = privacyFilter.excludedBundleIDs
        let bundleID = ownBundleID
        let pid = ownPID
        let scaleFactor = Double(NSScreen.main?.backingScaleFactor ?? 1.0)
        let frontmostPID = frontmost?.processIdentifier ?? 0
        let frontmostBundleID = frontmost?.bundleIdentifier

        let snapshot: DisplayCaptureSnapshot
        do {
            snapshot = try await Self.captureDisplaySnapshot(
                ownBundleID: bundleID,
                ownPID: pid,
                excludedBundleIDs: excludedIDs
            )
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }

        // Re-check privacy state in case a password manager activated while ScreenCaptureKit ran.
        guard !privacyFilter.isPaused else {
            throw CaptureError.privacyPaused(bundleID: privacyFilter.frontmostBundleID)
        }

        async let redactedImage = redactor.redact(image: snapshot.image)
        async let axElements: [AXElementBounds] = frontmostPID > 0
            ? axInspector.inspect(pid: frontmostPID, screenBounds: snapshot.displayBounds)
            : []

        let (finalImage, elements) = await (redactedImage, axElements)

        guard !privacyFilter.isPaused else {
            throw CaptureError.privacyPaused(bundleID: privacyFilter.frontmostBundleID)
        }

        let quality = jpegQuality
        let message = try await Task.detached(priority: .userInitiated) {
            try Self.buildContextMessage(
                redactedImage: finalImage,
                screenWidth: snapshot.logicalWidth,
                screenHeight: snapshot.logicalHeight,
                scaleFactor: scaleFactor,
                axElements: elements,
                frontmostBundleId: frontmostBundleID,
                jpegQuality: quality
            )
        }.value

        lastCaptureDate = Date()
        return message
    }

    /// Encodes a `CGImage` to JPEG `Data` at `quality` (default `0.65`) off `@MainActor`.
    nonisolated public static func encodeJPEG(
        image: CGImage,
        quality: Double = CaptureEngine.defaultJPEGQuality
    ) -> Data? {
        let clampedQuality = min(1.0, max(0.05, quality))
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }

    /// Assembles a `ScreenContextMessage` from an already-redacted `CGImage` and `AXElementBounds`.
    nonisolated public static func buildContextMessage(
        redactedImage: CGImage,
        screenWidth: Int,
        screenHeight: Int,
        scaleFactor: Double,
        axElements: [AXElementBounds],
        frontmostBundleId: String?,
        jpegQuality: Double = CaptureEngine.defaultJPEGQuality
    ) throws -> ScreenContextMessage {
        guard let jpegData = encodeJPEG(image: redactedImage, quality: jpegQuality) else {
            throw CaptureError.jpegEncodingFailed
        }
        return ScreenContextMessage(
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            scaleFactor: scaleFactor,
            jpegB64: jpegData.base64EncodedString(),
            axElements: axElements,
            frontmostBundleId: frontmostBundleId
        )
    }

    nonisolated private static func captureDisplaySnapshot(
        ownBundleID: String,
        ownPID: pid_t,
        excludedBundleIDs: Set<String>
    ) async throws -> DisplayCaptureSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        // Exclude Parhlo itself (to prevent feedback loops even on macOS 15+) plus protected apps.
        let excludedApps = content.applications.filter { app in
            app.processID == ownPID
                || app.bundleIdentifier == ownBundleID
                || PrivacyFilter.isExcluded(bundleIdentifier: app.bundleIdentifier, excludedBundleIDs: excludedBundleIDs)
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = max(1, display.width)
        config.height = max(1, display.height)
        config.showsCursor = true
        config.scalesToFit = true

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return DisplayCaptureSnapshot(
            image: cgImage,
            logicalWidth: display.width,
            logicalHeight: display.height,
            displayBounds: display.frame
        )
    }
}
