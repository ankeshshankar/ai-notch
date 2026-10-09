import AppKit
import QuartzCore
import SwiftUI

/// The notch's looping animations — the spinner, the waiting dot and the waiting glow — as
/// Core Animation layers. The render server runs the loop by itself at no more than 30 fps, so
/// the app does no work per frame and WindowServer redraws only the few points that move. The
/// animation is on the layer's own transform or opacity, never on its place: SwiftUI lays the
/// view out like any other, and nothing drifts while the shape around it resizes.
final class LoopLayerView: NSView {
    enum Kind: Equatable {
        /// A rotating arc, one turn every `period` seconds.
        case spinner(lineWidth: CGFloat)
        /// A dot that grows and shrinks.
        case dot
        /// The notch outline, breathing in opacity; `radius` is its bottom corners'.
        case glow(radius: CGFloat, lineWidth: CGFloat)
    }

    private let shape = CAShapeLayer()
    private var kind: Kind
    private var color: NSColor

    init(kind: Kind, color: NSColor) {
        self.kind = kind
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineCap = .round
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks and hover pass through to the SwiftUI view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(kind: Kind, color: NSColor) {
        let changed = kind != self.kind
        self.kind = kind
        self.color = color
        applyColor()
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = bounds
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.path = path(in: bounds)
        CATransaction.commit()
        applyColor()
        if shape.animation(forKey: "loop") == nil { startLoop() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        shape.contentsScale = window.backingScaleFactor
        // A view taken out of a window and put back loses its layer's animations.
        startLoop()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shape.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = self.color.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch kind {
        case .spinner(let lineWidth):
            shape.strokeColor = resolved
            shape.fillColor = nil
            shape.lineWidth = lineWidth
            shape.strokeStart = 0.08
            shape.strokeEnd = 0.72
        case .dot:
            shape.fillColor = resolved
            shape.strokeColor = nil
        case .glow(_, let lineWidth):
            shape.strokeColor = resolved
            shape.fillColor = nil
            shape.lineWidth = lineWidth
        }
        CATransaction.commit()
    }

    private func path(in rect: CGRect) -> CGPath {
        switch kind {
        case .spinner(let lineWidth):
            // From three o'clock, clockwise, like SwiftUI's trimmed circle.
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: min(inset.width, inset.height) / 2,
                        startAngle: 0, endAngle: -2 * .pi, clockwise: true)
            return path
        case .dot:
            return CGPath(ellipseIn: rect, transform: nil)
        case .glow(let radius, let lineWidth):
            // The stroke lies wholly inside the shape: what the old stroke left after the clip.
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let swiftUI = NotchShape(radius: max(0, radius - lineWidth / 2)).path(in: CGRect(origin: .zero, size: inset.size))
            // SwiftUI's paths run top-down; this layer's coordinates run bottom-up.
            var flip = CGAffineTransform(translationX: inset.minX, y: inset.maxY).scaledBy(x: 1, y: -1)
            return swiftUI.cgPath.copy(using: &flip) ?? swiftUI.cgPath
        }
    }

    private func startLoop() {
        shape.removeAnimation(forKey: "loop")
        let animation: CABasicAnimation
        switch kind {
        case .spinner:
            animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = -2 * Double.pi
            animation.duration = 0.9
        case .dot:
            animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = 0.8
            animation.toValue = 1.25
            animation.duration = 0.7
            animation.autoreverses = true
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        case .glow:
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.3
            animation.toValue = 0.95
            animation.duration = 0.9
            animation.autoreverses = true
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // WindowServer's cost follows the frame rate, not the size or the number of loops:
        // 36% of a core at the display's 120 Hz, 13% at 30.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        // Every copy on the same beat, whenever it started.
        let cycle = animation.duration * (animation.autoreverses ? 2 : 1)
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
        shape.add(animation, forKey: "loop")
    }
}

/// SwiftUI's handle on a `LoopLayerView`.
struct LoopLayer: NSViewRepresentable {
    var kind: LoopLayerView.Kind
    var color: NSColor

    func makeNSView(context: Context) -> LoopLayerView { LoopLayerView(kind: kind, color: color) }

    func updateNSView(_ view: LoopLayerView, context: Context) { view.update(kind: kind, color: color) }
}
