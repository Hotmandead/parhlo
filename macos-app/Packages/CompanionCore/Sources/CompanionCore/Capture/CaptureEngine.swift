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

internal struct DisplayCaptureSnapshot: Sendable {
    let image: CGImage
    let logicalWidth: Int
    let logicalHeight: Int
    let displayBounds: CGRect
    let scaleFactor: Double
    let displayID: CGDirectDisplayID
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
    @ObservationIgnored public let redactor: VisionRedactor
    @ObservationIgnored internal let axInspector: AXInspector
    @ObservationIgnored private let visionGrounder: VisionGrounder
    @ObservationIgnored private let ownBundleID: String
    @ObservationIgnored private let ownPID: pid_t
    @ObservationIgnored private let jpegQuality: Double

    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var isCaptureInFlight: Bool = false
    @ObservationIgnored private var lastExternalPID: pid_t = 0
    @ObservationIgnored private var lastExternalBundleID: String?
    @ObservationIgnored private var lastExternalAppName: String?
    @ObservationIgnored internal var snapshotProviderOverride: (@Sendable () async throws -> DisplayCaptureSnapshot)?

    public init(
        privacyFilter: PrivacyFilter,
        redactor: VisionRedactor = VisionRedactor(),
        axInspector: AXInspector? = nil,
        visionGrounder: VisionGrounder = VisionGrounder(),
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.parhlo.ScreenCompanionApp",
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        jpegQuality: Double = CaptureEngine.defaultJPEGQuality
    ) {
        self.privacyFilter = privacyFilter
        self.redactor = redactor
        self.axInspector = axInspector ?? AXInspector(redactor: redactor)
        self.visionGrounder = visionGrounder
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
        let initialFrontmost = NSWorkspace.shared.frontmostApplication
        let initialLivePID = initialFrontmost?.processIdentifier ?? 0
        let initialLiveBundleID = initialFrontmost?.bundleIdentifier
        let target = try evaluateLivePrivacyAndResolveTarget(frontmost: initialFrontmost)

        guard !isCaptureInFlight else {
            throw CaptureError.throttled
        }

        let now = Date()
        if respectRateLimit, let lastCaptureDate, now.timeIntervalSince(lastCaptureDate) < Self.minimumAllowedInterval {
            throw CaptureError.throttled
        }

        // Reserve the 1 FPS capture slot before any suspension point so concurrent calls cannot race.
        let previousCaptureDate = lastCaptureDate
        lastCaptureDate = now
        isCaptureInFlight = true
        defer { isCaptureInFlight = false }

        do {
            let excludedIDs = privacyFilter.excludedBundleIDs
            let bundleID = ownBundleID
            let pid = ownPID
            let screenContext = Self.collectScreenMetadata()

            let snapshot: DisplayCaptureSnapshot
            do {
                if let snapshotProviderOverride {
                    snapshot = try await snapshotProviderOverride()
                } else {
                    snapshot = try await Self.captureDisplaySnapshot(
                        ownBundleID: bundleID,
                        ownPID: pid,
                        excludedBundleIDs: excludedIDs,
                        targetPID: target.pid,
                        cursorDisplayID: screenContext.cursorDisplayID,
                        mainDisplayID: screenContext.mainDisplayID,
                        scaleFactorsByDisplayID: screenContext.scaleFactorsByDisplayID
                    )
                }
            } catch let error as CaptureError {
                throw error
            } catch {
                throw CaptureError.captureFailed(error.localizedDescription)
            }

            // Re-check privacy state in case a password manager activated while ScreenCaptureKit ran.
            try verifyLivePrivacy(initialBundleID: initialLiveBundleID, initialPID: initialLivePID)

            async let redaction = redactor.redactWithDetails(image: snapshot.image)
            async let axElements: [AXElementBounds] = (target.pid > 0 && target.pid != ownPID)
                ? axInspector.inspect(pid: target.pid, screenBounds: snapshot.displayBounds)
                : []

            let (redactionResult, elements) = await (redaction, axElements)
            let finalImage = redactionResult.image

            try verifyLivePrivacy(initialBundleID: initialLiveBundleID, initialPID: initialLivePID)

            let screenSize = CGSize(width: snapshot.logicalWidth, height: snapshot.logicalHeight)
            let detectedRects: [DetectedRectBounds]
            if AXInspector.isSparseTree(elements) {
                detectedRects = await visionGrounder.detectRectangles(in: finalImage, screenSize: screenSize)
            } else {
                detectedRects = []
            }

            let documentContext = await visionGrounder.extractDocumentContext(
                from: finalImage,
                redactor: redactor,
                fallbackText: redactionResult.sanitizedOCRText
            )

            // Re-evaluate live frontmost application right before returning.
            try verifyLivePrivacy(initialBundleID: initialLiveBundleID, initialPID: initialLivePID)

            let quality = jpegQuality
            let message = try await Task.detached(priority: .userInitiated) {
                try Self.buildContextMessage(
                    redactedImage: finalImage,
                    screenWidth: snapshot.logicalWidth,
                    screenHeight: snapshot.logicalHeight,
                    scaleFactor: snapshot.scaleFactor,
                    axElements: elements,
                    detectedRects: detectedRects,
                    documentContext: documentContext,
                    frontmostBundleId: target.bundleID,
                    jpegQuality: quality
                )
            }.value

            lastCaptureDate = Date()
            return message
        } catch {
            lastCaptureDate = previousCaptureDate
            throw error
        }
    }

    /// Captures a redacted on-device `OfflineScreenContext` snapshot without JPEG encoding for offline Q&A.
    public func captureOfflineContext() async throws -> OfflineScreenContext {
        let initialFrontmost = NSWorkspace.shared.frontmostApplication
        let initialLivePID = initialFrontmost?.processIdentifier ?? 0
        let initialLiveBundleID = initialFrontmost?.bundleIdentifier
        let target = try evaluateLivePrivacyAndResolveTarget(frontmost: initialFrontmost)

        let screenContext = Self.collectScreenMetadata()
        let snapshot: DisplayCaptureSnapshot
        if let snapshotProviderOverride {
            snapshot = try await snapshotProviderOverride()
        } else {
            snapshot = try await Self.captureDisplaySnapshot(
                ownBundleID: ownBundleID,
                ownPID: ownPID,
                excludedBundleIDs: privacyFilter.excludedBundleIDs,
                targetPID: target.pid,
                cursorDisplayID: screenContext.cursorDisplayID,
                mainDisplayID: screenContext.mainDisplayID,
                scaleFactorsByDisplayID: screenContext.scaleFactorsByDisplayID
            )
        }

        try verifyLivePrivacy(initialBundleID: initialLiveBundleID, initialPID: initialLivePID)

        async let redaction = redactor.redactWithDetails(image: snapshot.image)
        async let axElements: [AXElementBounds] = (target.pid > 0 && target.pid != ownPID)
            ? axInspector.inspect(pid: target.pid, screenBounds: snapshot.displayBounds)
            : []

        let (redactionResult, elements) = await (redaction, axElements)
        // Re-evaluate live frontmost application right before returning.
        try verifyLivePrivacy(initialBundleID: initialLiveBundleID, initialPID: initialLivePID)

        return OfflineScreenContext(
            sanitizedOCRText: redactionResult.sanitizedOCRText,
            axElements: elements,
            frontmostBundleID: target.bundleID,
            frontmostAppName: target.appName
        )
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
        detectedRects: [DetectedRectBounds] = [],
        documentContext: DocumentContext? = nil,
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
            frontmostBundleId: frontmostBundleId,
            detectedRects: detectedRects,
            documentContext: documentContext
        )
    }

    private func isSelfApplication(pid: pid_t, bundleIdentifier: String?) -> Bool {
        if pid > 0 && pid == ownPID {
            return true
        }
        if privacyFilter.isOwnApplication(bundleIdentifier) {
            return true
        }
        if let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           raw.caseInsensitiveCompare(ownBundleID) == .orderedSame {
            return true
        }
        return false
    }

    internal func resolveTargetApplication(
        frontmostPID: pid_t,
        frontmostBundleID: String?,
        frontmostAppName: String?
    ) throws -> (pid: pid_t, bundleID: String?, appName: String?) {
        if !isSelfApplication(pid: frontmostPID, bundleIdentifier: frontmostBundleID) {
            lastExternalPID = frontmostPID
            lastExternalBundleID = frontmostBundleID
            lastExternalAppName = frontmostAppName
            privacyFilter.evaluateFrontmostApplication(
                bundleIdentifier: frontmostBundleID,
                appName: frontmostAppName
            )
            guard !privacyFilter.isPaused else {
                throw CaptureError.privacyPaused(bundleID: privacyFilter.frontmostBundleID)
            }
            return (pid: frontmostPID, bundleID: frontmostBundleID, appName: frontmostAppName)
        }

        // Parhlo itself is active (e.g., Notch Drawer focused). Preserve any active privacy pause
        // and never inspect Parhlo's own PID with AXInspector.
        if let externalBundleID = lastExternalBundleID ?? privacyFilter.lastExternalBundleID ?? privacyFilter.frontmostBundleID,
           !isSelfApplication(pid: 0, bundleIdentifier: externalBundleID) {
            privacyFilter.evaluateFrontmostApplication(
                bundleIdentifier: externalBundleID,
                appName: lastExternalAppName ?? privacyFilter.lastExternalAppName ?? privacyFilter.frontmostAppName
            )
        }

        guard !privacyFilter.isPaused else {
            throw CaptureError.privacyPaused(bundleID: privacyFilter.frontmostBundleID)
        }

        var fallbackPID: pid_t = 0
        if lastExternalPID > 0, lastExternalPID != ownPID {
            if let running = NSRunningApplication(processIdentifier: lastExternalPID), !running.isTerminated {
                fallbackPID = lastExternalPID
            } else {
                lastExternalPID = 0
            }
        }

        return (
            pid: fallbackPID,
            bundleID: lastExternalBundleID ?? privacyFilter.lastExternalBundleID,
            appName: lastExternalAppName ?? privacyFilter.lastExternalAppName
        )
    }

    private func evaluateLivePrivacyAndResolveTarget(
        frontmost: NSRunningApplication?
    ) throws -> (pid: pid_t, bundleID: String?, appName: String?) {
        try resolveTargetApplication(
            frontmostPID: frontmost?.processIdentifier ?? 0,
            frontmostBundleID: frontmost?.bundleIdentifier,
            frontmostAppName: frontmost?.localizedName
        )
    }

    private func verifyLivePrivacy(initialBundleID: String?, initialPID: pid_t) throws {
        let liveFrontmost = NSWorkspace.shared.frontmostApplication
        let livePID = liveFrontmost?.processIdentifier ?? 0
        let liveBundleID = liveFrontmost?.bundleIdentifier
        let liveAppName = liveFrontmost?.localizedName

        if !isSelfApplication(pid: livePID, bundleIdentifier: liveBundleID) {
            let changedApp = livePID != initialPID || liveBundleID != initialBundleID
            if changedApp || privacyFilter.isExcluded(bundleIdentifier: liveBundleID) {
                lastExternalPID = livePID
                lastExternalBundleID = liveBundleID
                lastExternalAppName = liveAppName
                privacyFilter.evaluateFrontmostApplication(
                    bundleIdentifier: liveBundleID,
                    appName: liveAppName
                )
            }
        }

        guard !privacyFilter.isPaused else {
            throw CaptureError.privacyPaused(bundleID: privacyFilter.frontmostBundleID)
        }
    }

    private static func collectScreenMetadata() -> (
        cursorDisplayID: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID?,
        scaleFactorsByDisplayID: [CGDirectDisplayID: Double]
    ) {
        var scaleMap: [CGDirectDisplayID: Double] = [:]
        for screen in NSScreen.screens {
            if let displayID = screenDisplayID(screen) {
                scaleMap[displayID] = Double(screen.backingScaleFactor)
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(mouseLocation) }

        return (
            cursorDisplayID: cursorScreen.flatMap(screenDisplayID),
            mainDisplayID: NSScreen.main.flatMap(screenDisplayID),
            scaleFactorsByDisplayID: scaleMap
        )
    }

    private static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    nonisolated internal static func selectDisplayID(
        from displays: [(id: CGDirectDisplayID, frame: CGRect)],
        frontWindowFrame: CGRect?,
        cursorDisplayID: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let frontWindowFrame, !frontWindowFrame.isNull, !frontWindowFrame.isEmpty {
            if let matchedByWindow = displays
                .compactMap({ display -> (CGDirectDisplayID, CGFloat)? in
                    let intersection = display.frame.intersection(frontWindowFrame)
                    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                        return nil
                    }
                    return (display.id, intersection.width * intersection.height)
                })
                .max(by: { $0.1 < $1.1 })?.0 {
                return matchedByWindow
            }
        }

        if let cursorDisplayID, displays.contains(where: { $0.id == cursorDisplayID }) {
            return cursorDisplayID
        }

        if let mainDisplayID, displays.contains(where: { $0.id == mainDisplayID }) {
            return mainDisplayID
        }

        return displays.first?.id
    }

    nonisolated private static func captureDisplaySnapshot(
        ownBundleID: String,
        ownPID: pid_t,
        excludedBundleIDs: Set<String>,
        targetPID: pid_t,
        cursorDisplayID: CGDirectDisplayID?,
        mainDisplayID: CGDirectDisplayID?,
        scaleFactorsByDisplayID: [CGDirectDisplayID: Double]
    ) async throws -> DisplayCaptureSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw CaptureError.noDisplayFound
        }

        let frontWindowFrame: CGRect? = {
            guard targetPID > 0 else { return nil }
            let frontWindow = content.windows.first { window in
                window.owningApplication?.processID == targetPID
                    && window.windowLayer == 0
                    && window.isOnScreen
                    && window.frame.width > 1
                    && window.frame.height > 1
            } ?? content.windows.first { window in
                window.owningApplication?.processID == targetPID
                    && window.isOnScreen
                    && window.frame.width > 1
                    && window.frame.height > 1
            }
            return frontWindow?.frame
        }()

        let selectedID = selectDisplayID(
            from: content.displays.map { ($0.displayID, $0.frame) },
            frontWindowFrame: frontWindowFrame,
            cursorDisplayID: cursorDisplayID,
            mainDisplayID: mainDisplayID
        )

        guard let display = content.displays.first(where: { $0.displayID == selectedID }) ?? content.displays.first else {
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

        let matchedScaleFactor = scaleFactorsByDisplayID[display.displayID] ?? 1.0

        return DisplayCaptureSnapshot(
            image: cgImage,
            logicalWidth: display.width,
            logicalHeight: display.height,
            displayBounds: display.frame,
            scaleFactor: matchedScaleFactor,
            displayID: display.displayID
        )
    }
}
