import AppKit
import Combine
import NotchCore
import SwiftUI

// The collapsed notch's two wings. Left: a pet and one dot per session, coloured by its state,
// and a hammer when builds run. Right: the one thing that needs you, in a few words, then a
// glance at prod and at the weekly limit.
//
// Everything the wings show is derived once, by pure functions, into a `StripState`; `StripModel`
// publishes a new one only when it differs. The wings take narrow, equatable slices of it, so
// the strip does not redraw on the session store's one-second clock. Nothing in the strip loops
// while it is calm: motion is a one-shot on a change, or a gentle cue while something needs you,
// and not even that under Reduce Motion.

// MARK: Sessions as dots

/// What one session's dot says. Raw values rank urgency, for the "+n" that hides some.
enum DotState: Int, Equatable, Comparable {
    case idle, done, working, failed, waiting

    static func < (a: DotState, b: DotState) -> Bool { a.rawValue < b.rawValue }

    var word: String {
        switch self {
        case .idle: return "idle"
        case .done: return "done"
        case .working: return "working"
        case .failed: return "failed"
        case .waiting: return "waiting"
        }
    }
}

enum StripDots {
    /// Dots before the "+n".
    static let maxShown = 5
    /// A finished turn reads as "just done" for this long, then as idle.
    static let doneFor: Double = 30

    static func state(of session: SessionState, now: Double) -> DotState {
        switch session.phase {
        case .waiting: return .waiting
        case .working: return .working
        case .idle:
            // The turn ended on an API error: red until you ask again.
            if session.isFailed { return .failed }
            // A subagent of the latest turn that failed.
            let turn = session.turnStartedAt ?? 0
            if session.agents.contains(where: { $0.outcome == .failed && ($0.endedAt ?? 0) >= turn }) { return .failed }
            if let finished = session.finishedAt, now - finished < doneFor, now >= finished { return .done }
            return .idle
        }
    }

    /// Every session's dot in a stable order (when it began, then its id), so a dot never jumps
    /// when a state changes.
    static func list(_ sessions: [SessionState], now: Double) -> [DotState] {
        sessions
            .sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id }
            .map { state(of: $0, now: now) }
    }

    struct Shown: Equatable {
        var dots: [DotState]
        /// Sessions past `maxShown`.
        var more: Int
        /// The most urgent of those, to tint the "+n".
        var moreState: DotState?
    }

    static func shown(_ all: [DotState], max limit: Int = maxShown) -> Shown {
        let rest = all.dropFirst(limit)
        return Shown(dots: Array(all.prefix(limit)), more: rest.count, moreState: rest.max())
    }
}

// MARK: What needs the user, and the pet

/// Whether something wants the user now: a session waiting, or something that failed or alerts.
enum Attention: Equatable {
    case none, waiting, alarm

    static func of(waiting: Int, slot: WingSlot, sessionFailed: Bool) -> Attention {
        if waiting > 0 { return .waiting }
        if sessionFailed { return .alarm }
        switch slot {
        case .sessionFailed, .vpnDropped, .memoryCritical, .prodAlert, .deployWorse, .watchdog, .buildFailure: return .alarm
        default: return .none
        }
    }
}

enum PetPose: Equatable {
    case asleep, focused, waving, alarmed, celebrate

    /// Highest first: waiting on you, something wrong, just finished, working, idle.
    static func resolve(waiting: Bool, alarm: Bool, celebrating: Bool, working: Bool) -> PetPose {
        if waiting { return .waving }
        if alarm { return .alarmed }
        if celebrating { return .celebrate }
        if working { return .focused }
        return .asleep
    }
}

// MARK: Motion

enum EffectMode: Equatable {
    /// Nothing drawn.
    case hidden
    /// The style as a still picture, dimmed: the calm resting state.
    case resting
    /// The style as a still picture at full strength: the cue under Reduce Motion.
    case still
    case animated
}

enum GlowKind: Equatable {
    case amber, red
}

enum EffectGate {
    /// What the edge effect does. A waiting session has the amber glow to itself (as it always
    /// has). With "Calm until needed" the style rests until something failed or alerts, then
    /// loops as the cue (still, under Reduce Motion); resting is a still picture for Neon and
    /// Lights and nothing for Scanner and Aurora, which only make sense moving. Without it the
    /// style loops while an agent works (or always, when "Only while working" is off).
    static func mode(style: EffectsPrefs.Style, calm: Bool, reduceMotion: Bool, attention: Attention, busy: Bool, onlyWhileWorking: Bool) -> EffectMode {
        guard style != .off, attention != .waiting else { return .hidden }
        let moving: EffectMode = reduceMotion ? .still : .animated
        if !calm { return busy || !onlyWhileWorking ? moving : .hidden }
        if attention == .alarm { return moving }
        guard style == .neon || style == .lights, busy || !onlyWhileWorking else { return .hidden }
        return .resting
    }

    /// The outline that pulses (still under Reduce Motion) for a cue the edge effect does not
    /// give: amber while a session waits; red for a failure or alert when the style is off.
    static func glow(attention: Attention, calm: Bool, style: EffectsPrefs.Style) -> GlowKind? {
        switch attention {
        case .waiting: return .amber
        case .alarm: return calm && style == .off ? .red : nil
        case .none: return nil
        }
    }
}

/// The system's Reduce Motion setting, live.
@MainActor
final class MotionPrefs: ObservableObject {
    static let shared = MotionPrefs()
    @Published private(set) var reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var observer: Any?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if now != self.reduce { self.reduce = now }
            }
        }
    }
}

/// Animations that honour Reduce Motion: nil (an instant change) when the system asks for less.
@MainActor
enum Motion {
    static var reduce: Bool { MotionPrefs.shared.reduce }
    /// The open/close slide of a section or detail.
    static var slide: Animation? { reduce ? nil : .spring(response: 0.3, dampingFraction: 0.86) }
    static func spring(_ response: Double, _ damping: Double) -> Animation? { reduce ? nil : .spring(response: response, dampingFraction: damping) }
    static func ease(_ duration: Double) -> Animation? { reduce ? nil : .easeOut(duration: duration) }
    static func easeInOut(_ duration: Double) -> Animation? { reduce ? nil : .easeInOut(duration: duration) }
    /// A row that appears: slides in from the top, or only fades under Reduce Motion.
    static var rowIn: AnyTransition { reduce ? .opacity : .move(edge: .top).combined(with: .opacity) }
}

// MARK: Words and widths

enum WingWords {
    /// What the slot says, longest first (a shorter one is used when the wing is too narrow);
    /// empty for a slot that is only an icon and a number.
    static func candidates(_ slot: WingSlot) -> [String] {
        switch slot {
        case .waiting(let count): return ["\(count) waiting"]
        case .sessionFailed(let count): return count == 1 ? ["Session failed", "Failed"] : ["\(count) failed"]
        case .vpnDropped: return ["VPN dropped", "VPN"]
        case .memoryCritical: return ["Memory high", "Memory"]
        case .done: return ["Done"]
        case .prodAlert: return ["Prod alert", "Prod"]
        case .deployWorse: return ["Deploy worse", "Deploy"]
        case .watchdog: return ["Watchdog"]
        case .buildFailure: return ["Build failed", "Failed"]
        case .pullRequestNews(let count): return [count == 1 ? "1 PR update" : "\(count) PR updates", "\(count) PRs"]
        case .subagents, .none: return []
        }
    }

    /// The number beside the icon for the slots that show only that.
    static func number(_ slot: WingSlot) -> Int? {
        switch slot {
        case .subagents(let count): return count
        default: return nil
        }
    }

    /// What the slot says for a screen reader and the tooltip.
    static func spoken(_ slot: WingSlot) -> String? {
        switch slot {
        case .subagents(let count): return count == 1 ? "1 subagent running" : "\(count) subagents running"
        case .none: return nil
        default: return candidates(slot).first
        }
    }
}

enum WingMetrics {
    /// Each wing is at most this wide, so the strip does not run over the app menus or status items.
    static let cap: CGFloat = 120
    /// And at least this: the notch's own corner takes some.
    static let floor: CGFloat = 40
    static let padOuter: CGFloat = 8
    static let padInner: CGFloat = 6
    static let fontSize: CGFloat = Typo.Step.label.rawValue
    static let dot: CGFloat = 6
    static let dotGap: CGFloat = 3
    static let petWidth: CGFloat = CGFloat(PetArt.columns) * PetArt.pixel
    /// The weekly-limit bar: 14 x 4, where the ring was 11 across.
    static let barWidth: CGFloat = 14
    static let barHeight: CGFloat = 4
    static let iconWidth: CGFloat = 11
    /// Between a slot's icon and its words or number.
    static let iconGap: CGFloat = 3
    static let groupGap: CGFloat = 5
    static let itemGap: CGFloat = 4

    static func textWidth(_ text: String, size: CGFloat = fontSize, weight: NSFont.Weight = .semibold) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    /// "9+" past nine, so a count never takes more than two digits.
    static func buildsText(_ count: Int) -> String { count > 9 ? "9+" : "\(count)" }

    static func leftContent(shown: StripDots.Shown, hasSessions: Bool, builds: Int, petOn: Bool) -> CGFloat {
        var parts: [CGFloat] = []
        if petOn { parts.append(petWidth) }
        if hasSessions {
            let n = CGFloat(shown.dots.count)
            var dots = n * dot + max(0, n - 1) * dotGap
            if shown.more > 0 { dots += dotGap + textWidth("+\(shown.more)", size: 9) }
            parts.append(dots)
        } else if !petOn {
            parts.append(10)
        }
        if builds > 0 { parts.append(8 + 2 + textWidth(buildsText(builds), size: 10)) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * itemGap
    }

    static func healthWidth(prod: Bool, weekly: Bool) -> CGFloat {
        var parts: [CGFloat] = []
        if prod { parts.append(dot) }
        if weekly { parts.append(barWidth) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * dotGap
    }

    /// The slot's icon and number or words, at the longest wording.
    static func slotWidth(_ slot: WingSlot) -> CGFloat {
        if let number = WingWords.number(slot) { return iconWidth + iconGap + textWidth("\(number)") }
        if let words = WingWords.candidates(slot).first { return iconWidth + iconGap + textWidth(words) }
        return 0
    }

    static func rightContent(slot: WingSlot, prod: Bool, weekly: Bool) -> CGFloat {
        let slotW = slotWidth(slot), health = healthWidth(prod: prod, weekly: weekly)
        return slotW + health + (slotW > 0 && health > 0 ? groupGap : 0)
    }

    /// The dots that fit the left wing at the cap: five, fewer (down to three) beside the pet and
    /// the builds when more would not.
    static func leftShown(dots: [DotState], builds: Int, petOn: Bool) -> StripDots.Shown {
        var limit = StripDots.maxShown
        while true {
            let shown = StripDots.shown(dots, max: limit)
            if limit <= 3 || leftContent(shown: shown, hasSessions: !dots.isEmpty, builds: builds, petOn: petOn) + padOuter + padInner <= cap { return shown }
            limit -= 1
        }
    }

    /// Both wings the same width, the wider one's: the shape hangs from the screen's centre, where
    /// the hardware notch is, so unequal wings would put the notch off-centre in it.
    static func wing(_ state: StripState, petOn: Bool) -> CGFloat {
        let pad = padOuter + padInner
        let left = leftContent(shown: leftShown(dots: state.dots, builds: state.builds, petOn: petOn), hasSessions: !state.dots.isEmpty, builds: state.builds, petOn: petOn) + pad
        let right = rightContent(slot: state.slot, prod: state.prod != nil, weekly: state.weekly != nil) + pad
        return min(cap, max(floor, left, right)).rounded(.up)
    }

    /// The wording that fits the right wing at `wing` points beside the health glance, else the
    /// shortest (it truncates).
    static func words(for slot: WingSlot, wing: CGFloat, prod: Bool, weekly: Bool) -> String? {
        let candidates = WingWords.candidates(slot)
        guard !candidates.isEmpty else { return nil }
        let health = healthWidth(prod: prod, weekly: weekly)
        let room = wing - padOuter - padInner - health - (health > 0 ? groupGap : 0) - iconWidth - iconGap
        return candidates.first { textWidth($0) <= room } ?? candidates.last
    }
}

// MARK: Labels

enum WingLabels {
    static func left(dots: [DotState], builds: Int, lidAwake: Bool = false) -> String {
        var text: String
        if dots.isEmpty {
            text = "No sessions"
        } else {
            let counts = Dictionary(grouping: dots, by: { $0 }).mapValues(\.count)
            let parts = [DotState.waiting, .failed, .working, .done, .idle].compactMap { state in counts[state].map { "\($0) \(state.word)" } }
            text = "\(dots.count) \(dots.count == 1 ? "session" : "sessions"): \(parts.joined(separator: ", "))"
        }
        if builds > 0 { text += ". \(builds) \(builds == 1 ? "build" : "builds") running" }
        if lidAwake { text += ". Staying awake with the lid closed" }
        return text + "."
    }

    static func right(slot: WingSlot, prod: ProdStore.Level?, weekly: Int?) -> String {
        var parts: [String] = []
        if let spoken = WingWords.spoken(slot) { parts.append(spoken) }
        if let prod { parts.append(prodText(prod)) }
        if let weekly { parts.append("Weekly limit \(weekly)%") }
        return parts.isEmpty ? "Nothing needs you." : parts.joined(separator: ". ") + "."
    }

    static func prodText(_ level: ProdStore.Level) -> String {
        switch level {
        case .unknown: return "Prod unknown"
        case .ok: return "Prod OK"
        case .warn: return "Prod warning"
        case .alert: return "Prod alert"
        }
    }
}

/// The weekly ring's colour step: calm to 69%, amber to 89%, red from 90%.
enum RingStep: Equatable {
    case calm, warn, high

    static func of(_ percent: Int) -> RingStep { percent >= 90 ? .high : percent >= 70 ? .warn : .calm }
}

// MARK: The state the wings show

struct StripState: Equatable {
    var dots: [DotState] = []
    var builds = 0
    var slot: WingSlot = .none
    /// Prod's level, or nil to show no dot (not set up, off, snoozed, or no answer: no grey noise).
    var prod: ProdStore.Level?
    /// Claude Code's weekly use, rounded, while the window is current.
    var weekly: Int?
    var pose: PetPose = .asleep
    var attention: Attention = .none
    /// Something to say beyond the always-on glance: the strip shows even on a Mac with a notch.
    var hasReasons = false
    var hasSessions = false
    /// The right column of the open notch has rows (pipelines, or pull requests that need you).
    var hasRightRows = false
    var waiting = 0
    var busy = false
    var accent: AgentKind?
    var lastDoneAt: Double = 0
    var corner: Corner?

    enum Corner: Equatable { case prod, memory }
}

/// Plain values from the stores, so the derivation is pure.
struct StripInputs {
    var sessions: [SessionState] = []
    var now: Double = 0
    var lastDoneAt: Double = 0
    var runningAgents = 0
    var buildsActive = 0
    var buildsHasUnseenFailure = false
    var buildPassedRecently = false
    var buildRightRows = false
    /// Pull requests need something (the PRs chip's count is above zero).
    var prRightRows = false
    var vpnSlot = false
    var memorySlot = false
    var memoryDot = false
    var prodOn = false
    var prodSnoozed = false
    var prodLevel: ProdStore.Level = .unknown
    var prodOpenAlert = false
    var prodUnseenAlert = false
    var deployNews = false
    var watchdogNews = false
    var prNews = 0
    var weekly: LimitWindow?
}

/// When the open notch is two columns wide: one place for the rule.
enum WideRule {
    /// Panels that are columns themselves (PRs: Mine | To review; Board: four columns).
    static func isColumnPanel(_ panel: String?) -> Bool {
        panel == NotchController.boardPanel || panel == NotchController.pullRequestsPanel
    }
    /// Wide when the screen has room and either a column panel is open (even with no sessions or
    /// pipeline runs) or the agents have a right side to show (pipeline runs, or pull requests that need you).
    static func isWide(canGoWide: Bool, openPanel: String?, hasRightRows: Bool) -> Bool {
        canGoWide && (isColumnPanel(openPanel) || hasRightRows)
    }
}

extension StripState {
    static let justDoneFor: Double = 4

    static func make(_ i: StripInputs) -> StripState {
        let waiting = i.sessions.filter { $0.phase == .waiting }.count
        let working = i.sessions.filter { $0.phase == .working }
        let slot = WingSlot.pick(waiting: waiting, sessionFailures: i.sessions.filter(\.isFailed).count, vpnDropped: i.vpnSlot, memoryCritical: i.memorySlot, justDone: i.now - i.lastDoneAt < justDoneFor,
                                 prodAlert: i.prodUnseenAlert, buildFailure: i.buildsHasUnseenFailure, pullRequestNews: i.prNews,
                                 deployWorse: i.deployNews, watchdog: i.watchdogNews, subagents: i.runningAgents)
        let dots = StripDots.list(i.sessions, now: i.now)
        let sessionFailed = dots.contains(.failed)
        let attention = Attention.of(waiting: waiting, slot: slot, sessionFailed: sessionFailed)
        var state = StripState()
        state.dots = dots
        state.builds = i.buildsActive
        state.slot = slot
        state.prod = i.prodOn && !i.prodSnoozed && i.prodLevel != .unknown ? i.prodLevel : nil
        if let weekly = i.weekly, (weekly.resetsAt ?? .infinity) > i.now { state.weekly = Int(weekly.usedPercent.rounded()) }
        // The pet: waiting on you; something wrong (a session or subagent failed, prod is open,
        // a build failed); just finished (a turn, or a build that passed); working; asleep.
        let alarm = sessionFailed || i.prodOpenAlert || i.prodUnseenAlert || i.buildsHasUnseenFailure || attention == .alarm
        let celebrating = slot == .done || i.buildPassedRecently
        state.pose = PetPose.resolve(waiting: waiting > 0, alarm: alarm, celebrating: celebrating, working: !working.isEmpty || i.runningAgents > 0 || i.buildsActive > 0)
        state.attention = attention
        state.hasSessions = !i.sessions.isEmpty
        state.hasReasons = !i.sessions.isEmpty || i.buildsActive > 0 || i.buildsHasUnseenFailure || i.prodOpenAlert || i.prodUnseenAlert || i.deployNews
            || i.watchdogNews || i.memoryDot || i.memorySlot || i.vpnSlot || i.prNews > 0 || state.prod != nil || state.weekly != nil
        state.hasRightRows = !i.sessions.isEmpty && (i.buildRightRows || i.prRightRows)
        state.waiting = waiting
        state.busy = !working.isEmpty || i.runningAgents > 0 || i.buildsActive > 0
        state.accent = working.first?.kind
        state.lastDoneAt = i.lastDoneAt
        state.corner = i.prodOpenAlert && !i.prodSnoozed ? .prod : i.memoryDot ? .memory : nil
        return state
    }
}

/// Publishes the strip's `StripState` only when it changes. Its inputs publish often (the
/// session store's clock ticks every second); deriving is a few filters, and nothing redraws
/// unless the result differs.
@MainActor
final class StripModel: ObservableObject {
    @Published private(set) var state = StripState()
    private let store: SessionStore
    private let builds: BuildStore
    private let prod: ProdStore
    private let machine: MachineStore
    private let vpn: VPNStore
    private let reviews: ReviewStore
    private var bag: Set<AnyCancellable> = []

    init(store: SessionStore, builds: BuildStore, prod: ProdStore, machine: MachineStore, vpn: VPNStore, reviews: ReviewStore) {
        self.store = store
        self.builds = builds
        self.prod = prod
        self.machine = machine
        self.vpn = vpn
        self.reviews = reviews
        state = StripState.make(inputs())
        Publishers.MergeMany(store.objectWillChange, builds.objectWillChange, prod.objectWillChange, machine.objectWillChange,
                             vpn.objectWillChange, reviews.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &bag)
    }

    func refresh() {
        let next = StripState.make(inputs())
        if next != state { state = next }
    }

    private func inputs() -> StripInputs {
        var i = StripInputs()
        i.sessions = store.sessions
        i.now = store.now
        i.lastDoneAt = store.lastDoneAt
        i.runningAgents = store.runningAgents
        i.buildsActive = builds.activeCount
        i.buildsHasUnseenFailure = builds.hasUnseenFailure
        i.buildPassedRecently = builds.rows.contains { $0.state == .succeeded && store.now - ($0.finishedAt ?? 0) < StripState.justDoneFor }
        i.buildRightRows = builds.showsSection && !builds.rows.isEmpty
        i.prRightRows = reviews.isOn && !reviews.attention.isEmpty
        i.vpnSlot = vpn.showsSlot
        i.memorySlot = machine.showsSlot
        i.memoryDot = machine.showsDot
        i.prodOn = prod.isOn
        i.prodSnoozed = prod.isSnoozed
        i.prodLevel = prod.level
        i.prodOpenAlert = prod.hasOpenAlert
        i.prodUnseenAlert = prod.hasUnseenAlert
        i.deployNews = prod.hasDeployNews
        i.watchdogNews = prod.hasWatchdogNews
        i.prNews = reviews.unseenCount
        i.weekly = store.claudeLimits?.weekly
        // Dev only: a preview can show any level (`CLAUDE_NOTCH_PREVIEW_WEEKLY=90`).
        if CommandLine.arguments.contains("--preview"),
           let text = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_PREVIEW_WEEKLY"], let used = Double(text) {
            i.weekly = LimitWindow(usedPercent: used, resetsAt: nil, minutes: 10080)
        }
        return i
    }
}

// MARK: The pet

/// A 11 × 9 pixel-grid critter, drawn in code, two points a pixel. Each pose is a still picture;
/// waving has two, swapped by the view.
enum PetArt {
    static let columns = 11
    static let rows = 9
    static let pixel: CGFloat = 2

    // b body, d shade, w white, k dark, y amber, r red, g green, m muted.
    static func frame(_ pose: PetPose, wave: Bool = false) -> [String] {
        switch pose {
        case .focused:
            return ["...b...b...",
                    "..bbbbbbb..",
                    "..bddbddb..",
                    "..bwkbwkb..",
                    "..bbbbbbb..",
                    "..bbbdbbb..",
                    ".dbbbbbbbd.",
                    "..bbbbbbb..",
                    "..dd...dd.."]
        case .asleep:
            return ["...b...b.mm",
                    "..bbbbbbbm.",
                    "..bbbbbbbmm",
                    "..bbbbbbb..",
                    "..bkkbkkb..",
                    "..bbbbbbb..",
                    ".dbbbbbbbd.",
                    "..bbbbbbb..",
                    "..dd...dd.."]
        case .waving:
            return wave
                ? ["y..b...b...",
                   "y.bbbbbbb..",
                   "y.bbbbbbb..",
                   "..bwkbwkb..",
                   "y.bbbbbbb..",
                   "..bbbkbbbdd",
                   ".dbbbbbbb..",
                   "..bbbbbbb..",
                   "..dd...dd.."]
                : ["y..b...b...",
                   "y.bbbbbbb..",
                   "y.bbbbbbb..",
                   "..bwkbwkb.d",
                   "y.bbbbbbbd.",
                   "..bbbkbbbd.",
                   ".dbbbbbbb..",
                   "..bbbbbbb..",
                   "..dd...dd.."]
        case .alarmed:
            return ["...b...b..r",
                    "..bbbbbbb.r",
                    "..bbbbbbb.r",
                    "..bwwbwwb..",
                    "..bkwbkwb.r",
                    ".dbbbkbbbd.",
                    "..bbbbbbb..",
                    "..bbbbbbb..",
                    "..dd...dd.."]
        case .celebrate:
            return ["g..b...b..y",
                    "..bbbbbbb..",
                    "..bbbbbbb.g",
                    "..bkkbkkb..",
                    "y.bbbbbbb..",
                    ".dbbkkkbbd.",
                    "..bbbbbbb..",
                    "..bbbbbbb..",
                    "..dd...dd.."]
        }
    }

    static func color(_ ch: Character) -> Color? {
        switch ch {
        case "b": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "d": return Color(red: 0.60, green: 0.31, blue: 0.22)
        case "w": return .white
        case "k": return Color(red: 0.10, green: 0.07, blue: 0.07)
        case "y": return Palette.waitingHue
        case "r": return Palette.failedHue
        case "g": return Palette.doneHue
        case "m": return Color.white.opacity(0.55)
        default: return nil
        }
    }
}

private struct PetSprite: View {
    var pose: PetPose
    var wave: Bool

    var body: some View {
        let rows = PetArt.frame(pose, wave: wave)
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let color = PetArt.color(ch) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * PetArt.pixel, y: CGFloat(y) * PetArt.pixel, width: PetArt.pixel, height: PetArt.pixel)), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(PetArt.columns) * PetArt.pixel, height: CGFloat(PetArt.rows) * PetArt.pixel)
        .opacity(pose == .asleep ? 0.6 : 1)
    }
}

/// Flips `wave` every 0.7 s while it is on screen: the gentle cue while a session waits.
private struct WaveClock: View {
    @Binding var wave: Bool

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700))
                    wave.toggle()
                }
            }
    }
}

struct PetView: View {
    var pose: PetPose
    var reduceMotion: Bool
    @State private var wave = false
    @State private var pop = false

    var body: some View {
        PetSprite(pose: pose, wave: pose == .waving && wave)
            .scaleEffect(pop ? 1.22 : 1)
            .background { if pose == .waving, !reduceMotion { WaveClock(wave: $wave) } }
            // A pose change is a swap with one short bounce, nothing running after it.
            .onChange(of: pose) {
                guard !reduceMotion else { return }
                wave = false
                pop = true
                DispatchQueue.main.async { withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { pop = false } }
            }
    }
}

// MARK: The wings

struct LeftWingInput: Equatable {
    var dots: [DotState]
    var builds: Int
    var pose: PetPose
    var petOn: Bool
    var reduceMotion: Bool
    /// Calm off and Reduce Motion off: the pet and the dots move on their own layers.
    var animated = false
    /// Lid-awake is holding the Mac: only in the spoken label, no chip.
    var lidAwake = false
}

struct LeftWing: View, Equatable {
    var input: LeftWingInput

    var body: some View {
        let shown = WingMetrics.leftShown(dots: input.dots, builds: input.builds, petOn: input.petOn)
        HStack(spacing: WingMetrics.itemGap) {
            if input.petOn {
                if input.animated {
                    AnimatedPet(pose: input.pose, animated: true).frame(width: CGFloat(PetArt.columns) * PetArt.pixel, height: CGFloat(PetArt.rows) * PetArt.pixel)
                } else {
                    PetView(pose: input.pose, reduceMotion: input.reduceMotion)
                }
            }
            if input.dots.isEmpty {
                if !input.petOn { Image(systemName: "sparkle").font(Typo.label(.semibold)).foregroundStyle(Strip.ink3) }
            } else {
                HStack(spacing: WingMetrics.dotGap) {
                    ForEach(shown.dots.indices, id: \.self) { SessionDotView(state: shown.dots[$0], animated: input.animated) }
                    if shown.more > 0 {
                        Text("+\(shown.more)").font(Typo.caption(.semibold)).foregroundStyle(SessionDotView.color(shown.moreState ?? .idle, dim: Strip.ink2))
                    }
                }
                .animation(input.reduceMotion ? nil : .easeInOut(duration: 0.25), value: input.dots)
            }
            if input.builds > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "hammer.fill").font(Typo.micro())
                    Text(WingMetrics.buildsText(input.builds)).font(Typo.label(.semibold))
                }
                .foregroundStyle(Strip.ink2)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WingLabels.left(dots: input.dots, builds: input.builds, lidAwake: input.lidAwake))
        .help(WingLabels.left(dots: input.dots, builds: input.builds, lidAwake: input.lidAwake))
    }
}

struct SessionDotView: View {
    var state: DotState
    var animated = false

    static func color(_ state: DotState, dim: Color = Color.white.opacity(0.3)) -> Color {
        switch state {
        case .working: return Strip.claude
        case .waiting: return Strip.waiting
        case .done: return Strip.done
        case .failed: return Strip.failed
        case .idle: return dim
        }
    }

    var body: some View {
        // Idle is a hollow ring, so it reads without its colour.
        Group {
            if animated, DotMotion.cue(state) != .none {
                AnimatedDot(state: state, animated: true)
            } else if state == .idle {
                Circle().strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
            } else {
                Circle().fill(Self.color(state))
            }
        }
        .frame(width: WingMetrics.dot, height: WingMetrics.dot)
    }
}

struct RightWingInput: Equatable {
    var slot: WingSlot
    var prod: ProdStore.Level?
    var weekly: Int?
    var width: CGFloat
    var reduceMotion: Bool
}

struct RightWing: View, Equatable {
    var input: RightWingInput

    var body: some View {
        let words = WingMetrics.words(for: input.slot, wing: input.width, prod: input.prod != nil, weekly: input.weekly != nil)
        let label = WingLabels.right(slot: input.slot, prod: input.prod, weekly: input.weekly)
        HStack(spacing: WingMetrics.groupGap) {
            slotView(words: words)
            HStack(spacing: WingMetrics.dotGap) {
                if let level = input.prod { Circle().fill(Self.prodColor(level)).frame(width: WingMetrics.dot, height: WingMetrics.dot) }
                if let weekly = input.weekly { LimitBar(percent: weekly) }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    static func prodColor(_ level: ProdStore.Level) -> Color {
        switch level {
        case .unknown: return Strip.ink3
        case .ok: return Strip.done
        case .warn: return Strip.waiting
        case .alert: return Strip.failed
        }
    }

    @ViewBuilder
    private func slotView(words: String?) -> some View {
        let slot = input.slot
        HStack(spacing: WingMetrics.iconGap) {
            switch slot {
            case .waiting:
                LoopLayer(kind: .dot, color: Strip.waitingNS, animated: !input.reduceMotion).frame(width: 7, height: 7).frame(width: WingMetrics.iconWidth)
            case .sessionFailed:
                // A session's turn ended on an API error and nothing has been asked since.
                icon("exclamationmark.octagon.fill", Strip.failed)
            case .done:
                icon("checkmark", Strip.done, weight: .bold)
            case .prodAlert:
                // A monitor went to Alert, or an incident was declared, since the notch was last looked at.
                icon("exclamationmark.triangle.fill", Strip.failed, weight: .bold)
            case .deployWorse:
                // A linked service's new version has more errors or is slower than the one before.
                icon("chart.line.uptrend.xyaxis", Strip.failed, weight: .bold)
            case .watchdog:
                // Datadog's Watchdog found something since the notch was last looked at.
                icon("eye.fill", Strip.waiting)
            case .buildFailure:
                // A build or run failed since the notch was last opened.
                icon("xmark", Strip.failed, weight: .bold)
            case .subagents:
                icon("person.2.fill", Strip.ink2, step: .caption)
            case .vpnDropped:
                // A VPN connection ended without Disconnect: traffic no longer goes through it.
                icon("lock.slash.fill", Strip.failed)
            case .memoryCritical:
                icon("memorychip.fill", Strip.waiting)
            case .pullRequestNews:
                // News on pull requests since the notch was last looked at.
                icon("arrow.triangle.pull", Palette.bitbucketHue, step: .caption)
            case .none:
                EmptyView()
            }
            if let number = WingWords.number(slot) {
                Text("\(number)").font(Typo.label(.semibold)).foregroundStyle(Strip.ink2)
            } else if let words {
                Text(words).font(Typo.label(.semibold)).foregroundStyle(Self.wordColor(slot))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func icon(_ name: String, _ color: Color, step: Typo.Step = .label, weight: Font.Weight = .semibold) -> some View {
        Image(systemName: name).font(Typo.font(step, weight)).foregroundStyle(color).frame(width: WingMetrics.iconWidth)
    }

    static func wordColor(_ slot: WingSlot) -> Color {
        switch slot {
        case .waiting, .watchdog, .memoryCritical: return Strip.waiting
        case .done: return Strip.done
        case .sessionFailed, .prodAlert, .deployWorse, .buildFailure, .vpnDropped: return Strip.failed
        case .pullRequestNews: return Strip.ink
        default: return Strip.ink2
        }
    }
}

/// A small static bar: the weekly limit used, filled from the left. Never animated; it redraws
/// only when the rounded percent changes. Reads as a level, not a spinner.
struct LimitBar: View {
    var percent: Int

    /// The fill's width in points: 0 at 0%, the full bar at 100% and beyond, never negative.
    static func fillWidth(percent: Int) -> CGFloat {
        WingMetrics.barWidth * CGFloat(min(max(percent, 0), 100)) / 100
    }

    var body: some View {
        let color: Color = switch RingStep.of(percent) {
        case .calm: Color.white.opacity(0.7)
        case .warn: Strip.waiting
        case .high: Strip.failed
        }
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.2))
            Capsule().fill(color).frame(width: max(Self.fillWidth(percent: percent), percent > 0 ? WingMetrics.barHeight : 0))
        }
        .frame(width: WingMetrics.barWidth, height: WingMetrics.barHeight)
    }
}
