import AppKit
import QuartzCore
import SwiftUI

// The collapsed strip's own motion when "Calm until needed" is off: the pet and the working or
// waiting dots move on Core Animation layers, which the render server plays at no more than 30
// fps. Nothing in the app runs per frame. Every animation is removed, not hidden, while the
// screen is locked, the display sleeps, or the strip's window is not visible; under Reduce Motion
// the pet and dots stay in their still poses. With calm on, none of this is used.

enum StripMotion {
    /// Whether the strip is meant to move: calm off, and Reduce Motion off.
    static func animated(calm: Bool, reduceMotion: Bool) -> Bool { !calm && !reduceMotion }

    /// Whether a layer actually runs its animation right now.
    static func runs(animated: Bool, suspended: Bool, visible: Bool) -> Bool { animated && !suspended && visible }
}

enum DotMotion {
    enum Cue: Equatable { case none, soft, strong }

    /// Working: a gentle pulse. Waiting: a clearer one. Idle, done and failed stay still.
    static func cue(_ state: DotState) -> Cue {
        switch state {
        case .working: return .soft
        case .waiting: return .strong
        case .idle, .done, .failed: return .none
        }
    }
}

/// One animation of the pet: the pictures it shows in turn, and when each begins (0...1 of the cycle).
struct PetPlan: Equatable {
    var frames: [[String]]
    var starts: [Double]
    var seconds: Double
    var repeats: Float
    /// Up-and-down travel in points, and the breathe scale; either may be zero.
    var bob: CGFloat
    var breathe: CGFloat
}

enum PetMotion {
    static func blink(_ rows: [String]) -> [String] { rows.map { $0.replacingOccurrences(of: "w", with: "k") } }
    static func look(_ rows: [String]) -> [String] { rows.map { $0.replacingOccurrences(of: "wk", with: "kw") } }
    static func without(_ rows: [String], _ marks: Set<Character>) -> [String] {
        rows.map { String($0.map { marks.contains($0) ? "." : $0 }) }
    }

    static func plan(_ pose: PetPose) -> PetPlan {
        let base = PetArt.frame(pose)
        switch pose {
        case .focused:
            // Typing: the eyes flick, and every few seconds it blinks; a slight bob throughout.
            return PetPlan(frames: [base, look(base), base, blink(base), base], starts: [0, 0.3, 0.45, 0.88, 0.94],
                           seconds: 4, repeats: .infinity, bob: 0.6, breathe: 0)
        case .asleep:
            // A slow "zzz" and a slow breath.
            return PetPlan(frames: [base, without(base, ["m"])], starts: [0, 0.5], seconds: 3.6, repeats: .infinity, bob: 0, breathe: 0.04)
        case .waving:
            return PetPlan(frames: [PetArt.frame(.waving, wave: false), PetArt.frame(.waving, wave: true)], starts: [0, 0.5],
                           seconds: 1.4, repeats: .infinity, bob: 0, breathe: 0)
        case .alarmed:
            return PetPlan(frames: [base, without(base, ["r"])], starts: [0, 0.6], seconds: 1.2, repeats: .infinity, bob: 0, breathe: 0)
        case .celebrate:
            // A short celebration, then the pose holds.
            return PetPlan(frames: [base, without(base, ["g", "y"])], starts: [0, 0.5], seconds: 0.6, repeats: 4, bob: 1.5, breathe: 0)
        }
    }
}

// MARK: The gate

/// Locked screen and sleeping display, as one flag the layers watch.
@MainActor
enum MotionGate {
    static let changed = Notification.Name("ainotch.motion-gate-changed")
    private(set) static var suspended = BuildPolling.isScreenLocked
    private static var observers: [Any] = []

    static func start() {
        guard observers.isEmpty else { return }
        func set(_ value: Bool) {
            guard value != suspended else { return }
            suspended = value
            NotificationCenter.default.post(name: changed, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in MainActor.assumeIsolated { set(true) } },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in MainActor.assumeIsolated { set(false) } },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { set(true) } },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { set(BuildPolling.isScreenLocked) } },
        ]
    }
}

/// A layer host that plays only while the gate lets it, and takes the animations off otherwise.
@MainActor
class GatedLayerView: NSView {
    var animated = false { didSet { if animated != oldValue { refresh() } } }
    private var tokens: [Any] = []
    var playing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        MotionGate.start()
        tokens.append(NotificationCenter.default.addObserver(forName: MotionGate.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowTokens { NotificationCenter.default.removeObserver(token) }
        windowTokens = []
        if let window {
            windowTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

    private var windowTokens: [Any] = []

    var visible: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    func refresh() {
        let should = StripMotion.runs(animated: animated, suspended: MotionGate.suspended, visible: visible)
        if should { play() } else if playing || layer?.animationKeys()?.isEmpty == false { stop() }
        playing = should
    }

    func play() {}
    func stop() {}
}

// MARK: The pet

enum PetImages {
    private static var cache: [String: CGImage] = [:]

    @MainActor static func image(_ rows: [String]) -> CGImage? {
        let key = rows.joined(separator: "/")
        if let hit = cache[key] { return hit }
        let w = PetArt.columns, h = PetArt.rows
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = PetArt.color(ch) else { continue }
                context.setFillColor(NSColor(color).usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.white.cgColor)
                context.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
            }
        }
        let image = context.makeImage()
        if let image { cache[key] = image }
        return image
    }
}

final class PetLayerView: GatedLayerView {
    private let sprite = CALayer()
    private var pose: PetPose = .asleep

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(sprite)
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(pose: PetPose, animated: Bool) {
        let changed = pose != self.pose
        self.pose = pose
        showStill()
        if changed, animated, playing { stop(); playing = false }
        self.animated = animated
        refresh()
        if changed, animated, MotionGate.suspended == false { pop() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        sprite.position = CGPoint(x: bounds.midX, y: bounds.midY)
        sprite.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    private func showStill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = PetImages.image(PetArt.frame(pose))
        sprite.opacity = pose == .asleep ? 0.6 : 1
        CATransaction.commit()
    }

    private func pop() {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1.22
        spring.toValue = 1
        spring.mass = 1; spring.stiffness = 220; spring.damping = 11
        spring.duration = spring.settlingDuration
        spring.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        sprite.add(spring, forKey: "pop")
    }

    override func play() {
        guard sprite.animation(forKey: "frames") == nil else { return }
        let plan = PetMotion.plan(pose)
        let range = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = plan.frames.compactMap { PetImages.image($0) }
        frames.keyTimes = plan.starts.map { NSNumber(value: $0) }
        frames.calculationMode = .discrete
        frames.duration = plan.seconds
        frames.repeatCount = plan.repeats
        frames.preferredFrameRateRange = range
        if frames.values?.count == plan.starts.count { sprite.add(frames, forKey: "frames") }
        if plan.bob > 0 {
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0; bob.toValue = plan.bob
            bob.duration = plan.seconds / (plan.repeats == .infinity ? 2 : 1) / 2
            bob.autoreverses = true
            bob.repeatCount = plan.repeats == .infinity ? .infinity : plan.repeats * 2
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bob.preferredFrameRateRange = range
            sprite.add(bob, forKey: "bob")
        }
        if plan.breathe > 0 {
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 1; breathe.toValue = 1 + plan.breathe
            breathe.duration = plan.seconds / 2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.preferredFrameRateRange = range
            sprite.add(breathe, forKey: "breathe")
        }
    }

    override func stop() {
        sprite.removeAllAnimations()
    }
}

struct AnimatedPet: NSViewRepresentable {
    var pose: PetPose
    var animated: Bool

    func makeNSView(context: Context) -> PetLayerView { PetLayerView(frame: .zero) }
    func updateNSView(_ view: PetLayerView, context: Context) { view.update(pose: pose, animated: animated) }
}

// MARK: The dots

final class PulseDotView: GatedLayerView {
    private let shape = CAShapeLayer()
    private var cue = DotMotion.Cue.none

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(state: DotState, animated: Bool) {
        let newCue = DotMotion.cue(state)
        if newCue != cue { stop(); playing = false }
        cue = newCue
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.fillColor = NSColor(SessionDotView.color(state)).cgColor
        CATransaction.commit()
        self.animated = animated && newCue != .none
        refresh()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = bounds
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    override func play() {
        guard shape.animation(forKey: "pulse") == nil, cue != .none else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = cue == .soft ? 0.5 : 0.25
        fade.duration = cue == .soft ? 1.1 : 0.55
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        let cycle = fade.duration * 2
        fade.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
        shape.add(fade, forKey: "pulse")
        if cue == .strong {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1; grow.toValue = 1.3
            grow.duration = fade.duration
            grow.autoreverses = true
            grow.repeatCount = .infinity
            grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            grow.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            grow.timeOffset = fade.timeOffset
            shape.add(grow, forKey: "grow")
        }
    }

    override func stop() {
        shape.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.opacity = 1
        CATransaction.commit()
    }
}

struct AnimatedDot: NSViewRepresentable {
    var state: DotState
    var animated: Bool

    func makeNSView(context: Context) -> PulseDotView { PulseDotView(frame: .zero) }
    func updateNSView(_ view: PulseDotView, context: Context) { view.update(state: state, animated: animated) }
}
