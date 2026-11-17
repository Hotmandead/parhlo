import AppKit
import QuartzCore
import SwiftUI

/// SwiftUI bridge hosting the Core Animation `CAShapeLayer` vector renderer.
public struct VectorAnnotationLayerView: NSViewRepresentable {
    public let highlights: [DrawCommandMessage]
    public let arrows: [DrawCommandMessage]

    public init(highlights: [DrawCommandMessage], arrows: [DrawCommandMessage]) {
        self.highlights = highlights
        self.arrows = arrows
    }

    public func makeNSView(context: Context) -> VectorAnnotationNSView {
        let view = VectorAnnotationNSView(frame: .zero)
        view.update(highlights: highlights, arrows: arrows)
        return view
    }

    public func updateNSView(_ nsView: VectorAnnotationNSView, context: Context) {
        nsView.update(highlights: highlights, arrows: arrows)
    }
}

/// Layer-backed `NSView` drawing animated `CAShapeLayer` highlights, pulsing rings, and arrows.
@MainActor
public final class VectorAnnotationNSView: NSView {
    internal private(set) var annotationLayers: [String: CALayer] = [:]
    private var lastHighlights: [DrawCommandMessage] = []
    private var lastArrows: [DrawCommandMessage] = []
    private var renderedCommandsById: [String: DrawCommandMessage] = [:]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        rebuildAllLayers(animateNewOnly: false, previousCommands: renderedCommandsById)
    }

    public func update(highlights: [DrawCommandMessage], arrows: [DrawCommandMessage]) {
        let previousCommands = renderedCommandsById
        let oldIds = Set(previousCommands.keys)
        lastHighlights = highlights
        lastArrows = arrows
        let newIds = Set(highlights.map(\.commandId) + arrows.map(\.commandId))

        for removed in oldIds.subtracting(newIds) {
            renderedCommandsById.removeValue(forKey: removed)
            guard let removedLayer = annotationLayers.removeValue(forKey: removed) else { continue }
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                removedLayer.removeFromSuperlayer()
            }
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = removedLayer.presentation()?.opacity ?? removedLayer.opacity
            fadeOut.toValue = 0.0
            fadeOut.duration = 0.18
            fadeOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
            removedLayer.opacity = 0.0
            removedLayer.add(fadeOut, forKey: "fadeOut")
            CATransaction.commit()
        }

        rebuildAllLayers(animateNewOnly: true, previousCommands: previousCommands)
    }

    /// Resolves an arrow's start point in top-left pixel coordinates, synthesizing a ~56 pt diagonal
    /// offset origin clamped safely inside `canvasSize` when `explicitFrom` is `nil`.
    nonisolated public static func resolvedArrowStartPoint(
        from explicitFrom: Point2D?,
        to toPoint: Point2D,
        canvasSize: CGSize
    ) -> Point2D {
        if let explicitFrom {
            return explicitFrom
        }

        // 40x40 offset gives sqrt(40^2 + 40^2) ~= 56.6 pt diagonal shaft.
        let step = 40
        let edgeMargin = 12
        let width = max(1, Int(canvasSize.width.rounded()))
        let height = max(1, Int(canvasSize.height.rounded()))

        let dx = toPoint.x >= (step + edgeMargin * 2) ? -step : step
        let dy = toPoint.y >= (step + edgeMargin * 2) ? -step : step

        let minX = min(edgeMargin, width / 2)
        let maxX = max(minX, width - minX)
        let minY = min(edgeMargin, height / 2)
        let maxY = max(minY, height - minY)

        let clampedX = min(max(toPoint.x + dx, minX), maxX)
        let clampedY = min(max(toPoint.y + dy, minY), maxY)
        return Point2D(x: clampedX, y: clampedY)
    }

    /// Returns `true` when `style` enables the animated spotlight/pulse halo ring.
    nonisolated public static func shouldShowPulseRing(style: String?) -> Bool {
        guard let normalized = style?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "pulse" || normalized == "spotlight"
    }

    /// Returns trimmed non-empty label text if present on `command`.
    nonisolated public static func trimmedLabel(for command: DrawCommandMessage) -> String? {
        guard let raw = command.label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func rebuildAllLayers(
        animateNewOnly: Bool,
        previousCommands: [String: DrawCommandMessage]
    ) {
        guard let rootLayer = layer, bounds.width > 0, bounds.height > 0 else { return }

        for highlight in lastHighlights {
            guard let pixelRect = highlight.pixelRect else {
                annotationLayers.removeValue(forKey: highlight.commandId)?.removeFromSuperlayer()
                renderedCommandsById.removeValue(forKey: highlight.commandId)
                continue
            }
            let previous = previousCommands[highlight.commandId]
            let isNew = !animateNewOnly || previous == nil
            let needsRebuild = annotationLayers[highlight.commandId] == nil
                || !animateNewOnly
                || previous != highlight

            if needsRebuild {
                annotationLayers[highlight.commandId]?.removeFromSuperlayer()
                let container = makeHighlightLayer(
                    command: highlight,
                    pixelRect: pixelRect,
                    animate: isNew
                )
                rootLayer.addSublayer(container)
                annotationLayers[highlight.commandId] = container
            }
            renderedCommandsById[highlight.commandId] = highlight
        }

        for arrow in lastArrows {
            guard let toPoint = arrow.toPoint else {
                annotationLayers.removeValue(forKey: arrow.commandId)?.removeFromSuperlayer()
                renderedCommandsById.removeValue(forKey: arrow.commandId)
                continue
            }
            let fromPoint = Self.resolvedArrowStartPoint(
                from: arrow.fromPoint,
                to: toPoint,
                canvasSize: bounds.size
            )
            let previous = previousCommands[arrow.commandId]
            let isNew = !animateNewOnly || previous == nil
            let needsRebuild = annotationLayers[arrow.commandId] == nil
                || !animateNewOnly
                || previous != arrow

            if needsRebuild {
                annotationLayers[arrow.commandId]?.removeFromSuperlayer()
                let container = makeArrowLayer(
                    command: arrow,
                    fromPoint: fromPoint,
                    toPoint: toPoint,
                    animate: isNew
                )
                rootLayer.addSublayer(container)
                annotationLayers[arrow.commandId] = container
            }
            renderedCommandsById[arrow.commandId] = arrow
        }
    }

    private func makeHighlightLayer(
        command: DrawCommandMessage,
        pixelRect: PixelRect,
        animate: Bool
    ) -> CALayer {
        let container = CALayer()
        container.frame = bounds

        let rect = CoordinateConverter.toAppKitLocalRect(pixelRect, in: bounds.size)
        let color = HexColorParser.nsColor(from: command.color)
        let cornerRadius = min(12.0, min(rect.width, rect.height) * 0.22)
        let boxPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Optional pulsing spotlight ring behind the primary stroke.
        if Self.shouldShowPulseRing(style: command.style) {
            let pulseLayer = CAShapeLayer()
            let pulseRect = rect.insetBy(dx: -8, dy: -8)
            pulseLayer.frame = bounds
            pulseLayer.path = CGPath(
                roundedRect: pulseRect,
                cornerWidth: cornerRadius + 4,
                cornerHeight: cornerRadius + 4,
                transform: nil
            )
            pulseLayer.fillColor = NSColor.clear.cgColor
            pulseLayer.strokeColor = color.withAlphaComponent(0.55).cgColor
            pulseLayer.lineWidth = 2.0

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.98, 1.03, 0.98]
            scale.duration = 1.8
            scale.repeatCount = .infinity
            // Anchor scale around the highlight center rather than view origin.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            pulseLayer.bounds = bounds
            pulseLayer.position = center
            pulseLayer.anchorPoint = CGPoint(x: center.x / bounds.width, y: center.y / bounds.height)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.25, 0.85, 0.25]
            fade.duration = 1.8
            fade.repeatCount = .infinity

            pulseLayer.add(scale, forKey: "pulseScale")
            pulseLayer.add(fade, forKey: "pulseOpacity")
            container.addSublayer(pulseLayer)
        }

        let boxLayer = CAShapeLayer()
        boxLayer.frame = bounds
        boxLayer.path = boxPath
        boxLayer.fillColor = color.withAlphaComponent(0.10).cgColor
        boxLayer.strokeColor = color.cgColor
        boxLayer.lineWidth = 3.0
        boxLayer.lineCap = .round
        boxLayer.lineJoin = .round
        boxLayer.shadowColor = color.cgColor
        boxLayer.shadowRadius = 10.0
        boxLayer.shadowOpacity = 0.65
        boxLayer.shadowOffset = .zero

        if animate {
            let strokeAnim = CABasicAnimation(keyPath: "strokeEnd")
            strokeAnim.fromValue = 0.0
            strokeAnim.toValue = 1.0
            strokeAnim.duration = 0.35
            strokeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            boxLayer.add(strokeAnim, forKey: "strokeEnd")
        }

        container.addSublayer(boxLayer)

        if let labelText = Self.trimmedLabel(for: command) {
            let tagLayer = makeLabelTagLayer(
                text: labelText,
                accentColor: color,
                anchorRect: rect
            )
            container.addSublayer(tagLayer)
        }

        return container
    }

    private func makeArrowLayer(
        command: DrawCommandMessage,
        fromPoint: Point2D,
        toPoint: Point2D,
        animate: Bool
    ) -> CALayer {
        let container = CALayer()
        container.frame = bounds

        let start = CoordinateConverter.toAppKitLocalPoint(fromPoint, in: bounds.size)
        let end = CoordinateConverter.toAppKitLocalPoint(toPoint, in: bounds.size)
        let color = HexColorParser.nsColor(from: command.color, fallback: .systemGreen)

        // Offset midpoint slightly perpendicular to the vector for a natural curved Bezier shaft.
        let dx = end.x - start.x
        let dy = end.y - start.y
        let mid = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        let control = CGPoint(x: mid.x - dy * 0.16, y: mid.y + dx * 0.16)

        let shaftPath = CGMutablePath()
        shaftPath.move(to: start)
        shaftPath.addQuadCurve(to: end, control: control)

        let shaftLayer = CAShapeLayer()
        shaftLayer.frame = bounds
        shaftLayer.path = shaftPath
        shaftLayer.fillColor = NSColor.clear.cgColor
        shaftLayer.strokeColor = color.cgColor
        shaftLayer.lineWidth = 3.5
        shaftLayer.lineCap = .round
        shaftLayer.shadowColor = color.cgColor
        shaftLayer.shadowRadius = 8.0
        shaftLayer.shadowOpacity = 0.6
        shaftLayer.shadowOffset = .zero

        if animate {
            let drawAnim = CABasicAnimation(keyPath: "strokeEnd")
            drawAnim.fromValue = 0.0
            drawAnim.toValue = 1.0
            drawAnim.duration = 0.32
            drawAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shaftLayer.add(drawAnim, forKey: "strokeEnd")
        }

        // Compute tangent angle from control point to end point for arrowhead orientation.
        let angle = atan2(end.y - control.y, end.x - control.x)
        let headLength: CGFloat = 13.0
        let spread: CGFloat = .pi / 6.0

        let tipLeft = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let tipRight = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )

        let headPath = CGMutablePath()
        headPath.move(to: tipLeft)
        headPath.addLine(to: end)
        headPath.addLine(to: tipRight)

        let headLayer = CAShapeLayer()
        headLayer.frame = bounds
        headLayer.path = headPath
        headLayer.fillColor = NSColor.clear.cgColor
        headLayer.strokeColor = color.cgColor
        headLayer.lineWidth = 3.5
        headLayer.lineCap = .round
        headLayer.lineJoin = .round

        container.addSublayer(shaftLayer)
        container.addSublayer(headLayer)

        if let labelText = Self.trimmedLabel(for: command) {
            // Anchor the label near the arrow tail so it stays visible without obscuring the target point.
            let anchorRect = CGRect(x: start.x - 16, y: start.y - 4, width: 32, height: 8)
            let tagLayer = makeLabelTagLayer(
                text: labelText,
                accentColor: color,
                anchorRect: anchorRect
            )
            container.addSublayer(tagLayer)
        }

        return container
    }

    private func makeLabelTagLayer(
        text: String,
        accentColor: NSColor,
        anchorRect: CGRect
    ) -> CALayer {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 4
        let maxTagWidth = min(240, max(60, bounds.width - 16))
        let tagWidth = min(maxTagWidth, ceil(measured.width) + horizontalPadding * 2)
        let tagHeight = ceil(measured.height) + verticalPadding * 2

        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let maxOriginX = max(margin, bounds.width - tagWidth - margin)
        let originX = min(max(anchorRect.minX, margin), maxOriginX)

        // Prefer above the anchor rect (AppKit +Y is up); fall back below if too close to top edge.
        let preferredTopY = anchorRect.maxY + gap
        let fallbackBottomY = anchorRect.minY - tagHeight - gap
        let rawY: CGFloat
        if preferredTopY + tagHeight <= bounds.height - margin {
            rawY = preferredTopY
        } else if fallbackBottomY >= margin {
            rawY = fallbackBottomY
        } else {
            rawY = bounds.height - tagHeight - margin
        }
        let maxOriginY = max(margin, bounds.height - tagHeight - margin)
        let originY = min(max(rawY, margin), maxOriginY)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        let pill = CALayer()
        pill.frame = CGRect(x: originX, y: originY, width: tagWidth, height: tagHeight)
        pill.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 0.88).cgColor
        pill.borderColor = accentColor.withAlphaComponent(0.9).cgColor
        pill.borderWidth = 1.25
        pill.cornerRadius = tagHeight * 0.5
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.35
        pill.shadowRadius = 6
        pill.shadowOffset = CGSize(width: 0, height: -2)
        pill.contentsScale = scale

        let textLayer = CATextLayer()
        textLayer.frame = CGRect(
            x: horizontalPadding,
            y: floor((tagHeight - measured.height) * 0.5) - 0.5,
            width: tagWidth - horizontalPadding * 2,
            height: ceil(measured.height) + 1
        )
        textLayer.string = text
        textLayer.font = font
        textLayer.fontSize = 12
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.contentsScale = scale

        pill.addSublayer(textLayer)
        return pill
    }
}
