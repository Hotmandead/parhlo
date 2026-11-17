import ApplicationServices
import CoreGraphics
import Foundation

/// Off-main-actor Accessibility tree inspector capturing visible UI bounds for spatial grounding.
public actor AXInspector {
    public let maxDepth: Int
    public let maxElements: Int
    public let maxTextLength: Int
    nonisolated internal let redactor: VisionRedactor

    public init(
        maxDepth: Int = 6,
        maxElements: Int = 80,
        maxTextLength: Int = 120,
        redactor: VisionRedactor = VisionRedactor()
    ) {
        self.maxDepth = max(1, maxDepth)
        self.maxElements = max(1, maxElements)
        self.maxTextLength = max(16, maxTextLength)
        self.redactor = redactor
    }

    /// Traverses the Accessibility hierarchy for `pid` off `@MainActor` up to `maxDepth` and `maxElements`.
    public func inspect(pid: pid_t, screenBounds: CGRect? = nil) -> [AXElementBounds] {
        guard pid > 0, AXIsProcessTrusted() else {
            return []
        }

        let appElement = AXUIElementCreateApplication(pid)
        var results: [AXElementBounds] = []
        var queue: [(element: AXUIElement, depth: Int)] = []
        var visited = Set<AXElementKey>()

        // Prefer the focused window first if available so relevant controls appear within maxElements.
        if let focusedWindow = copyElement(kAXFocusedWindowAttribute as CFString, from: appElement) {
            queue.append((focusedWindow, 0))
            visited.insert(AXElementKey(focusedWindow))
        }

        let topChildren = copyChildren(from: appElement)
        for child in topChildren {
            let key = AXElementKey(child)
            if visited.insert(key).inserted {
                queue.append((child, 0))
            }
        }

        var cursor = 0
        while cursor < queue.count, results.count < maxElements {
            let (element, depth) = queue[cursor]
            cursor += 1

            if let bounds = extractBounds(from: element, screenBounds: screenBounds) {
                results.append(bounds)
                if results.count >= maxElements {
                    break
                }
            }

            guard depth < maxDepth else { continue }
            for child in copyChildren(from: element) {
                let key = AXElementKey(child)
                if visited.insert(key).inserted {
                    queue.append((child, depth + 1))
                }
            }
        }

        return results
    }

    nonisolated private static let containerRoles: Set<String> = [
        "AXApplication",
        "AXWindow",
        "AXScrollArea",
        "AXWebArea",
        "AXGroup",
    ]

    /// Returns `true` when the Accessibility tree is empty or has fewer than 4 non-container elements.
    nonisolated public static func isSparseTree(_ elements: [AXElementBounds]) -> Bool {
        guard !elements.isEmpty else { return true }
        let nonContainerCount = elements.reduce(into: 0) { count, element in
            if !Self.containerRoles.contains(element.role) {
                count += 1
            }
        }
        return nonContainerCount < 4
    }

    /// Filters out zero-sized or off-screen elements relative to `screenBounds`.
    nonisolated public static func isVisibleFrame(_ rect: CGRect, within screenBounds: CGRect?) -> Bool {
        guard rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else {
            return false
        }
        if let screenBounds {
            guard !screenBounds.isNull, !screenBounds.isEmpty else { return false }
            let intersection = rect.intersection(screenBounds)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }
        return true
    }

    /// Checks visibility against `screenBounds` and converts `rect.origin` into display-local top-left coordinates
    /// when `screenBounds` is non-nil (matching `0..W, 0..H`), preserving original coordinates when `nil`.
    nonisolated public static func displayLocalRect(
        _ rect: CGRect,
        within screenBounds: CGRect?
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard isVisibleFrame(rect, within: screenBounds) else {
            return nil
        }

        let localX: CGFloat
        let localY: CGFloat
        if let screenBounds {
            localX = rect.origin.x - screenBounds.origin.x
            localY = rect.origin.y - screenBounds.origin.y
        } else {
            localX = rect.origin.x
            localY = rect.origin.y
        }

        return (
            x: Int(localX.rounded()),
            y: Int(localY.rounded()),
            width: max(0, Int(rect.size.width.rounded())),
            height: max(0, Int(rect.size.height.rounded()))
        )
    }

    /// Sanitizes and truncates extracted AX strings, redacting secrets and secure field values.
    nonisolated public static func sanitizeText(
        _ raw: String?,
        role: String? = nil,
        isValueAttribute: Bool = false,
        maxLength: Int = 120,
        redactor: VisionRedactor? = nil
    ) -> String? {
        if isValueAttribute, role == (kAXTextFieldRole as String) || role == "AXSecureTextField" {
            if role == "AXSecureTextField" {
                return nil
            }
        }
        guard let raw else { return nil }
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return nil }

        if let redactor, redactor.containsSensitiveText(collapsed) {
            return "[REDACTED]"
        }

        guard collapsed.count > maxLength else {
            return collapsed
        }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: max(1, maxLength - 1))
        return String(collapsed[..<endIndex]) + "…"
    }

    private func extractBounds(from element: AXUIElement, screenBounds: CGRect?) -> AXElementBounds? {
        guard let role = copyString(kAXRoleAttribute as CFString, from: element),
              !role.isEmpty else {
            return nil
        }

        // Skip hidden or non-visible containers that lack valid geometry.
        guard let position = copyPoint(kAXPositionAttribute as CFString, from: element),
              let size = copySize(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }

        let rect = CGRect(origin: position, size: size)
        guard let localRect = Self.displayLocalRect(rect, within: screenBounds) else {
            return nil
        }

        let title = Self.sanitizeText(
            copyString(kAXTitleAttribute as CFString, from: element),
            role: role,
            maxLength: maxTextLength,
            redactor: redactor
        )
        let description = Self.sanitizeText(
            copyString(kAXDescriptionAttribute as CFString, from: element),
            role: role,
            maxLength: maxTextLength,
            redactor: redactor
        )
        let value = Self.sanitizeText(
            copyValueString(from: element),
            role: role,
            isValueAttribute: true,
            maxLength: maxTextLength,
            redactor: redactor
        )

        return AXElementBounds(
            role: role,
            title: title,
            description: description,
            value: value,
            x: localRect.x,
            y: localRect.y,
            width: localRect.width,
            height: localRect.height
        )
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value
    }

    private func copyString(_ attribute: CFString, from element: AXUIElement) -> String? {
        guard let raw = copyAttribute(attribute, from: element) else { return nil }
        if let str = raw as? String {
            return str
        }
        return nil
    }

    private func copyValueString(from element: AXUIElement) -> String? {
        guard let raw = copyAttribute(kAXValueAttribute as CFString, from: element) else { return nil }
        if let str = raw as? String {
            return str
        }
        if let attributed = raw as? NSAttributedString {
            return attributed.string
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func copyPoint(_ attribute: CFString, from element: AXUIElement) -> CGPoint? {
        guard let raw = copyAttribute(attribute, from: element),
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func copySize(_ attribute: CFString, from element: AXUIElement) -> CGSize? {
        guard let raw = copyAttribute(attribute, from: element),
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(attribute, from: element),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private func copyChildren(from element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(kAXChildrenAttribute as CFString, from: element),
              CFGetTypeID(raw) == CFArrayGetTypeID() else {
            return []
        }
        let cfArray = unsafeDowncast(raw, to: CFArray.self)
        let count = CFArrayGetCount(cfArray)
        guard count > 0 else { return [] }

        var children: [AXUIElement] = []
        children.reserveCapacity(count)
        for index in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let item = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
            if CFGetTypeID(item) == AXUIElementGetTypeID() {
                children.append(unsafeDowncast(item, to: AXUIElement.self))
            }
        }
        return children
    }
}

private struct AXElementKey: Hashable {
    private let hashValueRef: CFHashCode
    private let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        self.hashValueRef = CFHash(element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hashValueRef)
    }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
