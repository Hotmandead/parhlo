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
    private var annotationLayers: [String: CALayer] = [:]
    private var lastHighlights: [DrawCommandMessage] = []
    private var lastArrows: [DrawCommandMessage] = []

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
        rebuildAllLayers(animateNewOnly: false)
    }

    public func update(highlights: [DrawCommandMessage], arrows: [DrawCommandMessage]) {
        let oldIds = Set(lastHighlights.map(\.commandId) + lastArrows.map(\.commandId))
        lastHighlights = highlights
        lastArrows = arrows
        let newIds = Set(highlights.map(\.commandId) + arrows.map(\.commandId))

        for removed in oldIds.subtracting(newIds) {
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

        rebuildAllLayers(animateNewOnly: true, existingIds: oldIds)
    }

    private func rebuildAllLayers(animateNewOnly: Bool, existingIds: Set<String> = []) {
        guard let rootLayer = layer, bounds.width > 0, bounds.height > 0 else { return }

        for highlight in lastHighlights {
            guard let pixelRect = highlight.pixelRect else { continue }
            let isNew = !animateNewOnly || !existingIds.contains(highlight.commandId)
            if annotationLayers[highlight.commandId] == nil || !animateNewOnly {
                annotationLayers[highlight.commandId]?.removeFromSuperlayer()
                let container = makeHighlightLayer(
                    command: highlight,
                    pixelRect: pixelRect,
                    animate: isNew
                )
                rootLayer.addSublayer(container)
                annotationLayers[highlight.commandId] = container
            }
        }

        for arrow in lastArrows {
            guard let fromPoint = arrow.fromPoint, let toPoint = arrow.toPoint else { continue }
            let isNew = !animateNewOnly || !existingIds.contains(arrow.commandId)
            if annotationLayers[arrow.commandId] == nil || !animateNewOnly {
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
        if command.style == "pulse" {
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
        return container
    }
}
