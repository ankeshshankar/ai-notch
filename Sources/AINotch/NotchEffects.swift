import AppKit
import NotchCore
import QuartzCore
import SwiftUI

// The collapsed notch's light effects. The notch itself is the camera's cut-out, which has no
// pixels, so every effect lies around it: along the outside of its edge, or just under it. Like
// the spinner and the glow they are Core Animation layers the render server loops at no more than
// 30 fps; the app does no work per frame. They never take a click.

/// Setup's choice of effect, and when it plays. Read live by the notch.
@MainActor
final class EffectsPrefs: ObservableObject {
    static let shared = EffectsPrefs()

    enum Style: String, CaseIterable, Identifiable {
        case off
        /// A light that runs to and fro along the notch's edge, in the working agent's colour.
        case scanner
        /// The notch's edge in a slowly turning rainbow.
        case neon
        /// A string of coloured bulbs under the notch, twinkling.
        case lights
        /// Soft green, teal and violet light drifting under the notch.
        case aurora

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .scanner: return "Scanner"
            case .neon: return "Neon"
            case .lights: return "Lights"
            case .aurora: return "Aurora"
            }
        }
    }

    @Published var style: Style { didSet { save(style.rawValue, "effects.style") } }
    /// Only while an agent works (or a pipeline runs); else whenever the notch is closed.
    @Published var onlyWhileWorking: Bool { didSet { save(onlyWhileWorking, "effects.onlyWhileWorking") } }
    /// A soft light under the notch where the pointer is, as it comes near.
    @Published var pointerGlow: Bool { didSet { save(pointerGlow, "effects.pointerGlow") } }
    /// Sparkles from the notch when a turn finishes.
    @Published var sparkles: Bool { didSet { save(sparkles, "effects.sparkles") } }

    private init() {
        let defaults = UserDefaults.standard
        style = Style(rawValue: defaults.string(forKey: "effects.style") ?? "") ?? .scanner
        onlyWhileWorking = defaults.object(forKey: "effects.onlyWhileWorking") as? Bool ?? true
        pointerGlow = defaults.object(forKey: "effects.pointerGlow") as? Bool ?? true
        sparkles = defaults.object(forKey: "effects.sparkles") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}

/// Where the pointer is near the closed notch: its x across the notch (0 at its left edge) and
/// how near (1 at the edge, 0 at 100 points). Its own object, so only the glow redraws with it.
@MainActor
final class PointerFeed: ObservableObject {
    @Published private(set) var near: (x: CGFloat, strength: CGFloat)?

    static let reach: CGFloat = 100

    /// From the controller's pointer tick: the pointer and the closed shape, in screen points.
    func update(pointer: NSPoint, shape: NSRect, active: Bool) {
        guard active else {
            if near != nil { near = nil }
            return
        }
        // Below the shape, or beside it in the menu bar; nothing once it is far.
        let dx = max(shape.minX - pointer.x, 0, pointer.x - shape.maxX)
        let dy = max(shape.minY - pointer.y, 0)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance < Self.reach else {
            if near != nil { near = nil }
            return
        }
        let next = (x: min(max(pointer.x - shape.minX, 0), shape.width), strength: 1 - distance / Self.reach)
        if let near, abs(near.x - next.x) < 1.5, abs(near.strength - next.strength) < 0.04 { return }
        near = next
    }
}

/// The effects around the closed notch, sized to the shape plus `pad` on each side and below.
struct NotchEffects: View {
    @ObservedObject var prefs = EffectsPrefs.shared
    @ObservedObject var pointer: PointerFeed
    var size: CGSize
    /// The style plays (an agent works, or the user wants it always).
    var playing: Bool
    var accent: NSColor
    /// When the last turn finished, for the sparkles.
    var doneAt: Double

    static let pad: CGFloat = 14
    static let radius: CGFloat = 11

    var body: some View {
        ZStack {
            if playing, prefs.style != .off {
                EffectLayer(style: prefs.style, shape: size, accent: accent)
                    .transition(.opacity)
            }
            if prefs.pointerGlow {
                PointerGlowLayer(shape: size, near: pointer.near, color: prefs.style == .neon || prefs.style == .lights ? .systemPink : accent)
            }
            if prefs.sparkles {
                SparkleLayer(shape: size, token: doneAt)
            }
        }
        .frame(width: size.width + 2 * Self.pad, height: size.height + Self.pad)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.4), value: playing)
    }

    /// The working agent's colour, for the scanner and the glow.
    static func accent(for kind: AgentKind?) -> NSColor {
        switch kind {
        case .cursor?: return NSColor(srgbRed: 0.56, green: 0.52, blue: 0.91, alpha: 1)
        case .codex?: return NSColor(srgbRed: 0.30, green: 0.76, blue: 0.54, alpha: 1)
        case .gemini?: return NSColor(srgbRed: 0.26, green: 0.56, blue: 1.0, alpha: 1)
        case .other?: return NSColor(srgbRed: 0.40, green: 0.85, blue: 0.95, alpha: 1)
        default: return Strip.claudeNS
        }
    }
}

// MARK: Geometry shared by the layers

/// The notch's outline in a layer's (bottom-up) coordinates: down its left side, round its
/// bottom corners and up its right side, `offset` outside the shape. No top edge: that is the
/// screen's.
private func outline(shape: CGSize, in bounds: CGRect, offset: CGFloat) -> CGPath {
    let pad = NotchEffects.pad
    let left = pad - offset, right = pad + shape.width + offset
    let bottom = shape.height + offset
    let r = NotchEffects.radius + offset
    // Top-down first, then flipped.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: 0))
    path.addLine(to: CGPoint(x: left, y: bottom - r))
    path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + r, y: bottom), radius: r)
    path.addLine(to: CGPoint(x: right - r, y: bottom))
    path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom - r), radius: r)
    path.addLine(to: CGPoint(x: right, y: 0))
    var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
    return path.copy(using: &flip) ?? path
}

/// 30 fps at most: WindowServer's cost follows the frame rate, not the size.
private func looped(_ animation: CABasicAnimation, period: Double, reverses: Bool = false) -> CABasicAnimation {
    animation.duration = period
    animation.autoreverses = reverses
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    let cycle = period * (reverses ? 2 : 1)
    animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
    return animation
}

private func cg(_ color: NSColor, _ alpha: CGFloat = 1) -> CGColor { color.withAlphaComponent(alpha).cgColor }

// MARK: The styles

final class EffectLayerView: NSView {
    private var style: EffectsPrefs.Style
    private var shape: CGSize
    private var accent: NSColor
    private let root = CALayer()

    init(style: EffectsPrefs.Style, shape: CGSize, accent: NSColor) {
        self.style = style
        self.shape = shape
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(style: EffectsPrefs.Style, shape: CGSize, accent: NSColor) {
        guard style != self.style || shape != self.shape || accent != self.accent else { return }
        self.style = style
        self.shape = shape
        self.accent = accent
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A view taken out of a window and put back loses its layers' animations.
        if window != nil { rebuild() }
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.frame = bounds
        root.contentsScale = window?.backingScaleFactor ?? 2
        if bounds.width > 0, bounds.height > 0 {
            switch style {
            case .off: break
            case .scanner: scanner()
            case .neon: neon()
            case .lights: lights()
            case .aurora: aurora()
            }
        }
        CATransaction.commit()
    }

    /// A stroke along the outline, as a mask: what shows through it lights the notch's edge.
    private func edgeMask(width: CGFloat, offset: CGFloat) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = outline(shape: shape, in: bounds, offset: offset)
        mask.fillColor = nil
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = width
        mask.lineCap = .round
        return mask
    }

    /// A bright spot that sweeps from one side of the notch to the other and back, lighting its
    /// bottom edge and corners, with a dim trace of the whole edge.
    private func scanner() {
        let trace = CAShapeLayer()
        trace.frame = bounds
        trace.path = outline(shape: shape, in: bounds, offset: 1.5)
        trace.fillColor = nil
        trace.strokeColor = cg(accent, 0.22)
        trace.lineWidth = 1.5
        root.addSublayer(trace)

        let lit = CALayer()
        lit.frame = bounds
        lit.mask = edgeMask(width: 3, offset: 1.5)
        let beam = CAGradientLayer()
        let width = max(60, shape.width * 0.35)
        beam.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        beam.position = CGPoint(x: NotchEffects.pad, y: bounds.midY)
        beam.startPoint = CGPoint(x: 0, y: 0.5)
        beam.endPoint = CGPoint(x: 1, y: 0.5)
        beam.colors = [cg(accent, 0), cg(accent, 1), cg(.white, 1), cg(accent, 1), cg(accent, 0)]
        beam.locations = [0, 0.4, 0.5, 0.6, 1]
        lit.addSublayer(beam)
        lit.shadowColor = accent.cgColor
        lit.shadowOpacity = 1
        lit.shadowRadius = 4
        lit.shadowOffset = .zero
        root.addSublayer(lit)

        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = NotchEffects.pad - 4
        sweep.toValue = NotchEffects.pad + shape.width + 4
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        beam.add(looped(sweep, period: 1.6, reverses: true), forKey: "loop")
    }

    /// The edge in every colour, turning: a conic rainbow behind a stroke of the outline.
    private func neon() {
        let lit = CALayer()
        lit.frame = bounds
        lit.mask = edgeMask(width: 2.5, offset: 1.5)
        let side = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() * 1.1
        let wheel = CAGradientLayer()
        wheel.type = .conic
        wheel.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        wheel.position = CGPoint(x: bounds.midX, y: bounds.maxY - shape.height / 2)
        wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
        wheel.endPoint = CGPoint(x: 0.5, y: 0)
        let hues: [CGFloat] = [0, 0.08, 0.16, 0.33, 0.5, 0.62, 0.75, 0.88, 1]
        wheel.colors = hues.map { NSColor(hue: $0.truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 1, alpha: 1).cgColor }
        lit.addSublayer(wheel)
        lit.shadowColor = NSColor.systemPink.cgColor
        lit.shadowOpacity = 0.9
        lit.shadowRadius = 5
        lit.shadowOffset = .zero
        root.addSublayer(lit)

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        wheel.add(looped(turn, period: 4), forKey: "loop")
    }

    /// Bulbs in a row just under the notch, each twinkling on its own beat.
    private func lights() {
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPink, .systemOrange, .systemPurple]
        let count = max(6, Int(shape.width / 18))
        let y = bounds.height - shape.height - 4
        let wire = CAShapeLayer()
        wire.frame = bounds
        let path = CGMutablePath()
        let left = NotchEffects.pad + NotchEffects.radius, right = NotchEffects.pad + shape.width - NotchEffects.radius
        path.move(to: CGPoint(x: left, y: y + 2))
        path.addQuadCurve(to: CGPoint(x: right, y: y + 2), control: CGPoint(x: (left + right) / 2, y: y - 2))
        wire.path = path
        wire.fillColor = nil
        wire.strokeColor = NSColor(white: 0.5, alpha: 0.35).cgColor
        wire.lineWidth = 0.75
        root.addSublayer(wire)
        for index in 0..<count {
            let t = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let x = left + (right - left) * t
            // On the wire's curve.
            let sag = 4 * t * (1 - t) * 2
            let bulb = CALayer()
            bulb.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            bulb.cornerRadius = 2
            bulb.position = CGPoint(x: x, y: y + 2 - sag)
            let color = colors[index % colors.count]
            bulb.backgroundColor = color.cgColor
            bulb.shadowColor = color.cgColor
            bulb.shadowOpacity = 1
            bulb.shadowRadius = 3
            bulb.shadowOffset = .zero
            root.addSublayer(bulb)
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 1
            twinkle.toValue = 0.15
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let animation = looped(twinkle, period: 0.6 + Double(index % 4) * 0.17, reverses: true)
            animation.timeOffset += Double(index) * 0.23
            bulb.add(animation, forKey: "loop")
        }
    }

    /// Green, teal and violet light just under the notch, drifting sideways and fading downward.
    private func aurora() {
        let band = CALayer()
        let height: CGFloat = 9
        band.frame = CGRect(x: NotchEffects.pad - 6, y: bounds.height - shape.height - height, width: shape.width + 12, height: height)
        band.masksToBounds = true
        let fade = CAGradientLayer()
        fade.frame = band.bounds
        fade.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        // Bright at the notch's edge (the band's top), gone at its bottom.
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        band.mask = fade
        let ribbon = CAGradientLayer()
        let colors: [NSColor] = [
            NSColor(srgbRed: 0.20, green: 0.95, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.15, green: 0.75, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.60, green: 0.40, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.95, green: 0.35, blue: 0.80, alpha: 1),
        ]
        // The colours twice over, so the drift can loop by one period without a seam.
        ribbon.colors = (colors + colors + [colors[0]]).map { $0.cgColor }
        ribbon.startPoint = CGPoint(x: 0, y: 0.5)
        ribbon.endPoint = CGPoint(x: 1, y: 0.5)
        ribbon.anchorPoint = CGPoint(x: 0, y: 0.5)
        ribbon.bounds = CGRect(x: 0, y: 0, width: band.bounds.width * 2, height: height)
        ribbon.position = CGPoint(x: 0, y: height / 2)
        band.addSublayer(ribbon)
        band.shadowColor = colors[1].cgColor
        band.shadowOpacity = 0.8
        band.shadowRadius = 4
        band.shadowOffset = .zero
        root.addSublayer(band)

        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = 0
        drift.toValue = -band.bounds.width
        ribbon.add(looped(drift, period: 6), forKey: "loop")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 1
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(looped(breathe, period: 2.2, reverses: true), forKey: "breathe")
    }
}

struct EffectLayer: NSViewRepresentable {
    var style: EffectsPrefs.Style
    var shape: CGSize
    var accent: NSColor

    func makeNSView(context: Context) -> EffectLayerView { EffectLayerView(style: style, shape: shape, accent: accent) }

    func updateNSView(_ view: EffectLayerView, context: Context) { view.update(style: style, shape: shape, accent: accent) }
}

// MARK: The pointer's glow

/// A soft light under the notch's edge where the pointer is, brighter as it comes nearer.
final class PointerGlowView: NSView {
    private let spot = CAGradientLayer()
    private var shape: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spot.type = .radial
        spot.startPoint = CGPoint(x: 0.5, y: 0.5)
        spot.endPoint = CGPoint(x: 1, y: 1)
        spot.opacity = 0
        layer?.addSublayer(spot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(shape: CGSize, near: (x: CGFloat, strength: CGFloat)?, color: NSColor) {
        self.shape = shape
        spot.colors = [cg(color, 0.9), cg(color, 0.35), cg(color, 0)]
        spot.locations = [0, 0.45, 1]
        spot.bounds = CGRect(x: 0, y: 0, width: 110, height: 28)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if let near {
            // Centred on the notch's bottom edge, where the pointer is across it.
            spot.position = CGPoint(x: NotchEffects.pad + near.x, y: bounds.height - shape.height)
            spot.opacity = Float(near.strength * near.strength)
        } else {
            spot.opacity = 0
        }
        CATransaction.commit()
    }
}

struct PointerGlowLayer: NSViewRepresentable {
    var shape: CGSize
    var near: (x: CGFloat, strength: CGFloat)?
    var color: NSColor

    func makeNSView(context: Context) -> PointerGlowView { PointerGlowView(frame: .zero) }

    func updateNSView(_ view: PointerGlowView, context: Context) { view.update(shape: shape, near: near, color: color) }
}

// MARK: The sparkles

/// A burst of coloured sparks falling from the notch's bottom edge when a turn finishes.
final class SparkleView: NSView {
    private let emitter = CAEmitterLayer()
    private var lastToken: Double = 0
    private var seeded = false
    private static let dot: CGImage? = {
        let size = 8
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        emitter.emitterShape = .line
        emitter.renderMode = .additive
        emitter.birthRate = 0
        let colors: [NSColor] = [.systemPink, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemPurple]
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = Self.dot
            cell.color = color.cgColor
            cell.birthRate = 40
            cell.lifetime = 1.1
            cell.lifetimeRange = 0.4
            cell.velocity = 70
            cell.velocityRange = 40
            // Downward, fanned out: the layer's y runs up.
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 2.2
            cell.yAcceleration = -60
            cell.scale = 0.35
            cell.scaleRange = 0.2
            cell.scaleSpeed = -0.25
            cell.alphaSpeed = -0.9
            cell.spin = 2
            cell.spinRange = 4
            return cell
        }
        layer?.addSublayer(emitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(shape: CGSize, token: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: NotchEffects.pad + shape.width / 2, y: bounds.height - shape.height)
        emitter.emitterSize = CGSize(width: max(40, shape.width - 2 * NotchEffects.radius), height: 1)
        CATransaction.commit()
        // A new finish, not the one there was when the view appeared.
        defer { lastToken = token }
        guard seeded else {
            seeded = true
            return
        }
        guard token > lastToken, Date().timeIntervalSince1970 - token < 3 else { return }
        burst()
    }

    private func burst() {
        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.emitter.birthRate = 0 }
    }
}

struct SparkleLayer: NSViewRepresentable {
    var shape: CGSize
    var token: Double

    func makeNSView(context: Context) -> SparkleView { SparkleView(frame: .zero) }

    func updateNSView(_ view: SparkleView, context: Context) { view.update(shape: shape, token: token) }
}
