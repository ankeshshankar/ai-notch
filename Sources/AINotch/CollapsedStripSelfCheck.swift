import Foundation
import NotchCore

// `AINotch --strip-selfcheck`: the collapsed strip's pure parts on made-up inputs: the dots by
// session state (stable order, more than five), the words per slot, the wing width and its cap,
// the pet's priority, calm and attention gating of the edge effect, Reduce Motion, the labels, and
// that the one-second clock alone changes nothing. No UI. Exits 1 on any failure.

enum CollapsedStripSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--strip-selfcheck") else { return }
        exit(run())
    }

    static func session(_ id: String, _ phase: Phase, started: Double = 100, finished: Double? = nil, failedAgent: Bool = false) -> SessionState {
        var s = SessionState(id: id, cwd: "/tmp/x", now: started)
        s.phase = phase
        s.turnStartedAt = started + 1
        s.finishedAt = finished
        if failedAgent {
            var agent = AgentNow(id: "a-\(id)", type: "general", startedAt: started + 2)
            agent.end(.failed, at: started + 5)
            s.agents = [agent]
        }
        return s
    }

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(what)") }
        }

        // The wide rule: PRs need something -> wide; a column panel open -> wide even with nothing
        // else; no room -> narrow; a plain panel (Usage) does not widen.
        var wideIn = StripInputs(); wideIn.sessions = [session("w", .working)]
        expect(StripState.make(wideIn).hasRightRows == false, "wide: sessions only, no right side")
        wideIn.prRightRows = true
        expect(StripState.make(wideIn).hasRightRows, "wide: pull requests need something")
        wideIn.prRightRows = false; wideIn.buildRightRows = true
        expect(StripState.make(wideIn).hasRightRows, "wide: pipeline runs")
        var noSessions = StripInputs(); noSessions.prRightRows = true
        expect(!StripState.make(noSessions).hasRightRows, "wide: no sessions, no right column")
        expect(WideRule.isWide(canGoWide: true, openPanel: nil, hasRightRows: true), "wide: right rows, room")
        expect(!WideRule.isWide(canGoWide: true, openPanel: nil, hasRightRows: false), "narrow: nothing on the right")
        expect(WideRule.isWide(canGoWide: true, openPanel: NotchController.pullRequestsPanel, hasRightRows: false), "wide: PRs panel open, no sessions or runs")
        expect(WideRule.isWide(canGoWide: true, openPanel: NotchController.boardPanel, hasRightRows: false), "wide: Board panel open")
        expect(!WideRule.isWide(canGoWide: false, openPanel: NotchController.pullRequestsPanel, hasRightRows: true), "narrow: no room, PRs panel open")
        expect(!WideRule.isWide(canGoWide: false, openPanel: nil, hasRightRows: true), "narrow: no room")
        expect(!WideRule.isWide(canGoWide: true, openPanel: "Usage", hasRightRows: false), "narrow: Usage panel alone")

        // Dots: each state, and the order is stable (by start, then id), not by state.
        let now = 1_000.0
        expect(StripDots.state(of: session("a", .working), now: now) == .working, "working dot")
        expect(StripDots.state(of: session("a", .waiting), now: now) == .waiting, "waiting dot")
        expect(StripDots.state(of: session("a", .idle), now: now) == .idle, "idle dot")
        expect(StripDots.state(of: session("a", .idle, finished: now - 5), now: now) == .done, "just finished is done")
        expect(StripDots.state(of: session("a", .idle, finished: now - 31), now: now) == .idle, "done turns idle after 30 s")
        expect(StripDots.state(of: session("a", .idle, finished: now - 5, failedAgent: true), now: now) == .failed, "a failed subagent is failed, over done")
        expect(StripDots.state(of: session("a", .working, failedAgent: true), now: now) == .working, "working beats an old failure")
        let mixed = [session("c", .idle, started: 300), session("b", .working, started: 200), session("a", .waiting, started: 200), session("d", .working, started: 100)]
        expect(StripDots.list(mixed, now: now) == [.working, .waiting, .working, .idle], "stable order by start then id")
        var flipped = mixed
        flipped[1].phase = .waiting
        expect(StripDots.list(flipped, now: now).count == 4 && StripDots.list(flipped, now: now)[0] == .working, "a state change moves no dot")

        // More than five dots: the first five, a count, tinted by the most urgent hidden state.
        let eight = (0..<8).map { session("s\($0)", $0 == 6 ? .waiting : .working, started: Double(100 + $0)) }
        let shown = StripDots.shown(StripDots.list(eight, now: now))
        expect(shown.dots.count == 5 && shown.more == 3 && shown.moreState == .waiting, "8 sessions: 5 dots, +3, tinted waiting")
        expect(StripDots.shown([.idle, .done]).more == 0 && StripDots.shown([.idle, .done]).moreState == nil, "2 sessions: no more")
        expect(StripDots.shown(Array(repeating: .idle, count: 5)).more == 0, "5 sessions: no more")
        expect(StripDots.shown(Array(repeating: .idle, count: 6)).more == 1, "6 sessions: +1")

        // Words per slot.
        let words: [(WingSlot, String?)] = [
            (.waiting(2), "2 waiting"), (.vpnDropped, "VPN dropped"), (.memoryCritical, "Memory high"), (.done, "Done"),
            (.prodAlert, "Prod alert"), (.deployWorse, "Deploy worse"), (.watchdog, "Watchdog"), (.buildFailure, "Build failed"),
            (.pullRequestNews(3), "3 PR updates"), (.pullRequestNews(1), "1 PR update"), (.subagents(2), nil), (.none, nil),
        ]
        for (slot, expected) in words { expect(WingWords.candidates(slot).first == expected, "words \(slot): \(expected ?? "none")") }
        expect(WingWords.number(.subagents(2)) == 2 && WingWords.number(.waiting(1)) == nil, "number slots")

        // The slot order is unchanged.
        expect(WingSlot.pick(waiting: 1, vpnDropped: true, memoryCritical: true, justDone: true, prodAlert: true, buildFailure: true, pullRequestNews: 2, deployWorse: true, watchdog: true, subagents: 1) == .waiting(1), "waiting first")
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: true, pullRequestNews: 2, subagents: 1) == .buildFailure, "failure before PR news")
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: false, subagents: 0) == WingSlot.none, "builds never take the right wing: the left shows them")

        // Part C: builds show on the left only. A running build never fills the right wing, and
        // with a subagent running the right wing says that (the next slot), not the build.
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: false, subagents: 2) == .subagents(2), "right wing falls through to subagents")
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: true, subagents: 0) == .buildFailure, "a failed build still takes the right wing")

        // Wing width: floor when calm, the cap with the longest words and everything else, the same
        // for both wings, and the chosen wording always fits or is the shortest.
        var calm = StripState()
        calm.hasReasons = true
        expect(WingMetrics.wing(calm, petOn: true) >= WingMetrics.floor && WingMetrics.wing(calm, petOn: false) == WingMetrics.floor, "calm wing is compact: \(WingMetrics.wing(calm, petOn: true)) / \(WingMetrics.wing(calm, petOn: false))")
        expect(WingMetrics.wing(calm, petOn: true) <= 60, "calm wing with a pet is at most 60")
        var busy = StripState()
        busy.dots = Array(repeating: .working, count: 9)
        busy.builds = 12
        busy.prod = .alert
        busy.weekly = 95
        for slot in words.map(\.0) {
            busy.slot = slot
            let wing = WingMetrics.wing(busy, petOn: true)
            expect(wing <= WingMetrics.cap, "wing \(wing) within the cap for \(slot)")
            if let text = WingMetrics.words(for: slot, wing: wing, prod: true, weekly: true) {
                let health = WingMetrics.healthWidth(prod: true, weekly: true)
                let room = wing - WingMetrics.padOuter - WingMetrics.padInner - health - WingMetrics.groupGap - WingMetrics.iconWidth - WingMetrics.iconGap
                expect(WingMetrics.textWidth(text) <= room || text == WingWords.candidates(slot).last, "words fit or are the shortest for \(slot): \(text)")
            }
        }
        // The weekly-limit bar: a level, 14 x 4, steps as the ring had them.
        let bar = WingMetrics.barWidth
        expect(WingMetrics.barWidth >= 14 && WingMetrics.barWidth <= 16 && WingMetrics.barHeight == 4, "limit bar is 14-16 wide and 4 tall")
        expect(LimitBar.fillWidth(percent: 0) == 0, "limit bar 0%: empty")
        expect(LimitBar.fillWidth(percent: 50) == bar / 2, "limit bar 50%: half")
        expect(abs(LimitBar.fillWidth(percent: 90) - bar * 0.9) < 0.001, "limit bar 90%: nine tenths")
        expect(LimitBar.fillWidth(percent: 100) == bar, "limit bar 100%: full")
        expect(LimitBar.fillWidth(percent: 140) == bar && LimitBar.fillWidth(percent: -3) == 0, "limit bar clamps over 100 and under 0")
        expect(RingStep.of(0) == .calm && RingStep.of(50) == .calm && RingStep.of(89) == .warn && RingStep.of(90) == .high && RingStep.of(100) == .high && RingStep.of(140) == .high, "limit bar colour steps: calm, warn, high")
        var noLimit = StripState(); noLimit.prod = .ok
        var withLimit = noLimit; withLimit.weekly = 50
        expect(StripState.make(StripInputs()).weekly == nil, "limit bar: no data, no bar")
        expect(WingMetrics.healthWidth(prod: true, weekly: true) - WingMetrics.healthWidth(prod: true, weekly: false) == WingMetrics.dotGap + bar, "limit bar width counted in the wing")
        expect(WingMetrics.wing(withLimit, petOn: false) - WingMetrics.wing(noLimit, petOn: false) <= WingMetrics.dotGap + bar + 0.5, "limit bar adds only its own width to the wing")
        var wide = StripState()
        wide.slot = .pullRequestNews(3)
        wide.prod = .ok
        wide.weekly = 40
        let wideWing = WingMetrics.wing(wide, petOn: true)
        expect(wideWing > WingMetrics.wing(calm, petOn: true) && wideWing <= WingMetrics.cap, "words widen the wing within the cap: \(wideWing)")
        expect(WingMetrics.words(for: .pullRequestNews(3), wing: 100, prod: false, weekly: false) == "3 PR updates", "3 PR updates fit when there is room")
        expect(WingMetrics.words(for: .pullRequestNews(3), wing: 60, prod: true, weekly: true) == "3 PRs", "a narrow wing takes the short wording")
        let fullest = WingMetrics.leftShown(dots: Array(repeating: .working, count: 9), builds: 12, petOn: true)
        let fullestWidth = WingMetrics.leftContent(shown: fullest, hasSessions: true, builds: 12, petOn: true) + WingMetrics.padOuter + WingMetrics.padInner
        expect(fullestWidth <= WingMetrics.cap && fullest.dots.count >= 3 && fullest.dots.count + fullest.more == 9, "left wing at its fullest fits the cap with fewer dots: \(fullest.dots.count) dots, \(fullestWidth) pt")
        expect(WingMetrics.leftShown(dots: Array(repeating: .working, count: 9), builds: 0, petOn: true).dots.count == 5, "no builds: five dots even for nine sessions")

        // The pet: highest first.
        expect(PetPose.resolve(waiting: true, alarm: true, celebrating: true, working: true) == .waving, "pet: waiting first")
        expect(PetPose.resolve(waiting: false, alarm: true, celebrating: true, working: true) == .alarmed, "pet: alarm over celebrate")
        expect(PetPose.resolve(waiting: false, alarm: false, celebrating: true, working: true) == .celebrate, "pet: celebrate over working")
        expect(PetPose.resolve(waiting: false, alarm: false, celebrating: false, working: true) == .focused, "pet: working")
        expect(PetPose.resolve(waiting: false, alarm: false, celebrating: false, working: false) == .asleep, "pet: asleep")
        for pose in [PetPose.asleep, .focused, .waving, .alarmed, .celebrate] {
            for wave in [false, true] {
                let frame = PetArt.frame(pose, wave: wave)
                expect(frame.count == PetArt.rows && frame.allSatisfy { $0.count == PetArt.columns }, "pet art \(pose) \(wave) is \(PetArt.columns)x\(PetArt.rows)")
                expect(frame.joined().allSatisfy { $0 == "." || PetArt.color($0) != nil }, "pet art \(pose) uses known colours")
            }
        }
        expect(Double(PetArt.rows) * Double(PetArt.pixel) <= 18, "pet is at most 18 pt tall")

        // Calm and attention gating of the edge effect, and Reduce Motion.
        func mode(_ style: EffectsPrefs.Style = .lights, calm: Bool = true, reduce: Bool = false, _ attention: Attention = .none, busy: Bool = false, only: Bool = true) -> EffectMode {
            EffectGate.mode(style: style, calm: calm, reduceMotion: reduce, attention: attention, busy: busy, onlyWhileWorking: only)
        }
        expect(mode(.off, .alarm) == .hidden, "style off draws nothing")
        expect(mode(.lights, .waiting) == .hidden && mode(.scanner, calm: false, .waiting, busy: true) == .hidden, "waiting: the amber glow has it alone")
        expect(mode(.scanner, busy: true) == .hidden && mode(.aurora, busy: true, only: false) == .hidden, "calm: scanner and aurora rest hidden, even while working")
        expect(mode(.lights, busy: true) == .resting && mode(.neon, busy: true) == .resting, "calm: lights and neon rest still while working")
        expect(mode(.lights, busy: false, only: true) == .hidden && mode(.lights, busy: false, only: false) == .resting, "calm: resting follows Only while working")
        expect(mode(.scanner, .alarm) == .animated && mode(.lights, .alarm) == .animated, "calm: a failure animates the style")
        expect(mode(.scanner, reduce: true, .alarm) == .still && mode(.neon, reduce: true, .alarm) == .still, "Reduce Motion: a failure is still, at full strength")
        expect(mode(.lights, calm: false, busy: true) == .animated && mode(.scanner, calm: false, busy: false, only: true) == .hidden && mode(.scanner, calm: false, busy: false, only: false) == .animated, "calm off: the old behaviour")
        expect(mode(.lights, calm: false, reduce: true, busy: true) == .still, "calm off under Reduce Motion: still")
        expect(EffectGate.glow(attention: .waiting, calm: true, style: .lights) == .amber && EffectGate.glow(attention: .waiting, calm: false, style: .off) == .amber, "waiting: amber glow")
        expect(EffectGate.glow(attention: .alarm, calm: true, style: .off) == .red && EffectGate.glow(attention: .alarm, calm: true, style: .neon) == nil && EffectGate.glow(attention: .alarm, calm: false, style: .off) == nil, "alarm: red glow only when the style is off and calm is on")
        expect(EffectGate.glow(attention: .none, calm: true, style: .off) == nil, "no attention, no glow")

        // Attention from the slot and sessions.
        expect(Attention.of(waiting: 1, slot: .none, sessionFailed: false) == .waiting, "attention: waiting")
        expect(Attention.of(waiting: 0, slot: .buildFailure, sessionFailed: false) == .alarm && Attention.of(waiting: 0, slot: .prodAlert, sessionFailed: false) == .alarm && Attention.of(waiting: 0, slot: .none, sessionFailed: true) == .alarm, "attention: failure and alert")
        expect(Attention.of(waiting: 0, slot: .done, sessionFailed: false) == .none && Attention.of(waiting: 0, slot: .pullRequestNews(2), sessionFailed: false) == .none, "attention: done and PR news are not")

        // The state: derived from plain inputs, and the clock alone changes nothing.
        var input = StripInputs()
        input.sessions = [session("a", .working, started: 100), session("b", .idle, started: 101)]
        input.now = 500
        input.lastDoneAt = 10
        input.prodOn = true
        input.prodLevel = .ok
        input.weekly = LimitWindow(usedPercent: 63.6, resetsAt: 9_999, minutes: 10080)
        let a = StripState.make(input)
        input.now = 501
        expect(a == StripState.make(input), "one second later, the same state")
        expect(a.dots == [.working, .idle] && a.pose == .focused && a.prod == .ok && a.weekly == 64 && a.attention == .none && a.hasReasons, "state from two sessions")
        input.prodSnoozed = true
        expect(StripState.make(input).prod == nil, "snoozed prod: no dot")
        input.prodSnoozed = false
        input.prodLevel = .unknown
        expect(StripState.make(input).prod == nil, "unknown prod: no grey dot")
        input.prodOn = false
        input.prodLevel = .alert
        expect(StripState.make(input).prod == nil, "prod off: no dot")
        input.weekly = LimitWindow(usedPercent: 63, resetsAt: 400, minutes: 10080)
        expect(StripState.make(input).weekly == nil, "a window past its reset: no ring")
        input.lastDoneAt = 499
        expect(StripState.make(input).slot == .done && StripState.make(input).pose == .celebrate, "just done: the word and the pet celebrate")
        input.now = 504
        expect(StripState.make(input).slot == .none, "done fades after 4 s")
        input.sessions[0].phase = .waiting
        let waiting = StripState.make(input)
        expect(waiting.attention == .waiting && waiting.pose == .waving && waiting.slot == .waiting(1) && waiting.waiting == 1, "a waiting session: attention, pet waves, slot")
        input.sessions = []
        input.prodOpenAlert = true
        input.prodOn = true
        let alert = StripState.make(input)
        expect(alert.pose == .alarmed && alert.corner == .prod, "an open prod alert: pet alarmed, corner dot")
        expect(!StripState.make(StripInputs()).hasReasons, "nothing at all: no wings on a notched Mac")
        var ring = StripInputs()
        ring.weekly = LimitWindow(usedPercent: 20, resetsAt: nil, minutes: nil)
        expect(StripState.make(ring).hasReasons, "a weekly limit alone shows the wings (the always-on glance)")

        // Ring steps, labels.
        expect(RingStep.of(69) == .calm && RingStep.of(70) == .warn && RingStep.of(89) == .warn && RingStep.of(90) == .high && RingStep.of(100) == .high, "ring steps")
        expect(WingLabels.left(dots: [.waiting, .working, .working], builds: 0) == "3 sessions: 1 waiting, 2 working.", "left label: \(WingLabels.left(dots: [.waiting, .working, .working], builds: 0))")
        expect(WingLabels.left(dots: [.idle], builds: 2) == "1 session: 1 idle. 2 builds running.", "left label with builds: \(WingLabels.left(dots: [.idle], builds: 2))")
        expect(WingLabels.left(dots: [], builds: 0) == "No sessions.", "left label, none")
        expect(WingLabels.right(slot: .none, prod: .ok, weekly: 64) == "Prod OK. Weekly limit 64%.", "right label: \(WingLabels.right(slot: .none, prod: .ok, weekly: 64))")
        expect(WingLabels.right(slot: .waiting(2), prod: nil, weekly: nil) == "2 waiting.", "right label, waiting")
        expect(WingLabels.right(slot: .subagents(1), prod: .alert, weekly: nil) == "1 subagent running. Prod alert.", "right label, subagent: \(WingLabels.right(slot: .subagents(1), prod: .alert, weekly: nil))")
        expect(WingLabels.right(slot: .none, prod: nil, weekly: nil) == "Nothing needs you.", "right label, nothing")

        // Strip motion: only with calm off and Reduce Motion off; layers run only when not suspended and visible.
        expect(StripMotion.animated(calm: false, reduceMotion: false), "calm off: the strip moves")
        expect(!StripMotion.animated(calm: true, reduceMotion: false), "calm on: the strip is as built before")
        expect(!StripMotion.animated(calm: false, reduceMotion: true), "Reduce Motion: static poses")
        expect(StripMotion.runs(animated: true, suspended: false, visible: true), "layers run when awake and visible")
        expect(!StripMotion.runs(animated: true, suspended: true, visible: true), "locked screen or sleeping display removes the animations")
        expect(!StripMotion.runs(animated: true, suspended: false, visible: false), "a strip not visible removes the animations")
        expect(!StripMotion.runs(animated: false, suspended: false, visible: true), "not animated never runs")
        expect(DotMotion.cue(.working) == .soft && DotMotion.cue(.waiting) == .strong, "working pulses softly, waiting more clearly")
        expect([DotState.idle, .done, .failed].allSatisfy { DotMotion.cue($0) == .none }, "idle, done and failed dots stay still")
        for pose in [PetPose.asleep, .focused, .waving, .alarmed, .celebrate] {
            let plan = PetMotion.plan(pose)
            expect(plan.frames.count == plan.starts.count && plan.starts.first == 0 && plan.starts == plan.starts.sorted() && plan.frames.count <= 5 && plan.frames.allSatisfy { $0.count == PetArt.rows && $0.allSatisfy { $0.count == PetArt.columns } },
                   "pet plan for \(pose): a few well-formed frames")
        }
        expect(PetMotion.plan(.focused).frames[3] != PetArt.frame(.focused) && PetMotion.plan(.asleep).frames[1] != PetArt.frame(.asleep), "the pet blinks while awake and the zzz comes and goes")

        print(failures == 0 ? "strip selfcheck: \(checks)/\(checks) ok" : "strip selfcheck: \(failures) of \(checks) FAILED")
        return failures == 0 ? 0 : 1
    }
}
