import AppKit
import Foundation
import Observation

/// Enforces bundle-ID exclusions and pauses capture whenever a protected app gains focus.
@MainActor
@Observable
public final class PrivacyFilter {
    /// Default bundle identifiers for password managers and credential vaults.
    nonisolated public static let defaultExcludedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
    ]

    public private(set) var excludedBundleIDs: Set<String>
    public private(set) var isPaused: Bool = false
    public private(set) var frontmostBundleID: String?
    public private(set) var frontmostAppName: String?

    @ObservationIgnored public var onPauseStateChanged: ((Bool, String?) -> Void)?

    @ObservationIgnored private weak var overlayStore: OverlayStateStore?
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(
        excludedBundleIDs: Set<String> = PrivacyFilter.defaultExcludedBundleIDs,
        overlayStore: OverlayStateStore? = nil
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.overlayStore = overlayStore
    }

    deinit {
        observationTask?.cancel()
    }

    /// Pure thread-safe check determining whether `bundleIdentifier` belongs to `excludedBundleIDs`.
    nonisolated public static func isExcluded(
        bundleIdentifier: String?,
        excludedBundleIDs: Set<String> = PrivacyFilter.defaultExcludedBundleIDs
    ) -> Bool {
        guard let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let target = raw.lowercased()
        return excludedBundleIDs.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target }
    }

    /// Checks whether `bundleIdentifier` is excluded under this filter's active configuration.
    public func isExcluded(bundleIdentifier: String?) -> Bool {
        Self.isExcluded(bundleIdentifier: bundleIdentifier, excludedBundleIDs: excludedBundleIDs)
    }

    public func attachOverlayStore(_ store: OverlayStateStore?) {
        self.overlayStore = store
    }

    public func addExcludedBundleID(_ bundleIdentifier: String) {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        excludedBundleIDs.insert(trimmed)
        evaluateFrontmostApplication(bundleIdentifier: frontmostBundleID, appName: frontmostAppName)
    }

    public func removeExcludedBundleID(_ bundleIdentifier: String) {
        let target = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        excludedBundleIDs = excludedBundleIDs.filter { $0.lowercased() != target }
        evaluateFrontmostApplication(bundleIdentifier: frontmostBundleID, appName: frontmostAppName)
    }

    public func setExcludedBundleIDs(_ bundleIdentifiers: Set<String>) {
        excludedBundleIDs = Set(
            bundleIdentifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        evaluateFrontmostApplication(bundleIdentifier: frontmostBundleID, appName: frontmostAppName)
    }

    /// Starts observing `NSWorkspace.didActivateApplicationNotification` and evaluates the current frontmost app.
    public func startObserving() {
        stopObserving()

        let current = NSWorkspace.shared.frontmostApplication
        evaluateFrontmostApplication(
            bundleIdentifier: current?.bundleIdentifier,
            appName: current?.localizedName
        )

        observationTask = Task { @MainActor [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await notification in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                guard !Task.isCancelled else { break }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.evaluateFrontmostApplication(
                    bundleIdentifier: app?.bundleIdentifier,
                    appName: app?.localizedName
                )
            }
        }
    }

    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Evaluates a frontmost application change and notifies listeners + HUD when privacy pause toggles.
    public func evaluateFrontmostApplication(bundleIdentifier: String?, appName: String? = nil) {
        frontmostBundleID = bundleIdentifier
        frontmostAppName = appName

        let shouldPause = isExcluded(bundleIdentifier: bundleIdentifier)
        let changed = shouldPause != isPaused
        isPaused = shouldPause

        if shouldPause {
            overlayStore?.setPrivacyPaused(true, appName: appName ?? bundleIdentifier)
        } else if changed {
            overlayStore?.setPrivacyPaused(false, appName: nil)
        }

        if changed {
            onPauseStateChanged?(shouldPause, bundleIdentifier)
        }
    }
}
