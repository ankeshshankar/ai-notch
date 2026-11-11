import AppKit
import Foundation
import IOKit
import VPNCore

// Keeps the Mac awake with the lid CLOSED while agents work. An IOKit assertion cannot do that on
// an Apple-silicon MacBook without an external display; only the system's SleepDisabled flag can
// (`pmset -a disablesleep 1`, root). So this asks AI Notch's root helper (the one the VPN uses,
// ai-notch-vpnd) for a short sleep-disable lease and renews it while the plan says so. If the app
// quits, is killed or the Mac loses it, the lease ends by itself (90 s) and the helper clears the
// flag. See VPNCore/SleepLease.swift for the helper side and why it is safe.
//
// Heat: a closed lid with the Mac working has nowhere for the heat to go. Do not use it in a bag.

/// When the lease is wanted, and why not when it is not. Pure, so the self-check can run it.
enum LidAwakePlan {
    /// On battery, at or below this charge (percent) it lets go ...
    static let lowBattery = 20
    /// ... and only comes back above this one, so it does not flap at the edge.
    static let rearm = 25
    /// After a serious or critical thermal state, this long (seconds) at a lower one before it returns.
    static let coolDown: Double = 60

    enum Heat: Int, Equatable {
        case nominal, fair, serious, critical

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .serious
            }
        }
    }

    /// What the app can say about the helper: speaking the lease protocol, not installed or not
    /// answering, or installed from before the lease existed.
    enum Helper: Equatable { case ok, missing, old }

    /// Why the Mac is not being held. `noAgent` is the armed state: everything is ready.
    enum Reason: Equatable {
        case off, helperMissing, helperOld, batteryLow, hot, noAgent
        /// The flag was already on and not set by the helper.
        case managedElsewhere
        /// The helper was asked and could not hold the flag.
        case helperFailed
    }

    /// What the plan remembers between calls, for the hysteresis.
    struct Latch: Equatable {
        /// The charge fell to the limit and has not come back above the re-arm level.
        var batteryLocked = false
        /// The last time the Mac was seen hot.
        var lastHot: Double?
    }

    struct Inputs {
        var enabled: Bool
        var working: Bool
        /// When a session or build was last seen working; nil when none has been.
        var lastWorking: Double?
        var now: Double
        var power: KeepAwakePlan.Power
        var heat: Heat
        var helper: Helper
    }

    /// Nil: hold the lease. Else the reason not to. The latch is updated on every call.
    static func decide(_ i: Inputs, latch: inout Latch) -> Reason? {
        if i.power.onBattery {
            let percent = i.power.percent ?? 100
            if percent <= lowBattery { latch.batteryLocked = true } else if percent > rearm { latch.batteryLocked = false }
        } else {
            latch.batteryLocked = false
        }
        if i.heat.rawValue >= Heat.serious.rawValue { latch.lastHot = i.now }
        guard i.enabled else { return .off }
        switch i.helper {
        case .missing: return .helperMissing
        case .old: return .helperOld
        case .ok: break
        }
        if i.power.onBattery, latch.batteryLocked { return .batteryLow }
        if let hot = latch.lastHot, i.now - hot < coolDown || i.heat.rawValue >= Heat.serious.rawValue { return .hot }
        guard i.working || i.lastWorking.map({ i.now - $0 < KeepAwakePlan.grace }) == true else { return .noAgent }
        return nil
    }

    /// Whether to put the built-in display to sleep: the lid is closed, no external display is
    /// attached, and it has not been done for this close.
    static func shouldSleepDisplay(lidClosed: Bool, externalDisplay: Bool, alreadyDone: Bool) -> Bool {
        lidClosed && !externalDisplay && !alreadyDone
    }
}

/// The published state, and the words for it.
enum LidAwakeStatus: Equatable {
    case active
    /// On, ready, waiting for an agent.
    case armed
    case off(LidAwakePlan.Reason)

    var line: String {
        switch self {
        case .active: return "Active: the Mac stays awake if you close the lid"
        case .armed: return "Armed: waits for an agent"
        case .off(let reason):
            switch reason {
            case .off: return "Off"
            case .noAgent: return "Armed: waits for an agent"
            case .helperMissing: return "Needs the helper (Setup)"
            case .helperOld: return "Helper update needed (Setup)"
            case .batteryLow: return "Paused: battery at \(LidAwakePlan.lowBattery)% or less"
            case .hot: return "Paused: the Mac is running hot"
            case .managedElsewhere: return "Sleep is already disabled by something else"
            case .helperFailed: return "The helper could not keep the Mac awake"
            }
        }
    }

    /// For the log: one word and the reason's kind.
    var logKind: String {
        switch self {
        case .active: return "active"
        case .armed: return "armed"
        case .off(let reason): return "off (\(reason))"
        }
    }
}

/// Holds, renews and releases the lease as the plan says; fed from the store's reload.
@MainActor
final class LidAwake: ObservableObject {
    static let shared = LidAwake()

    /// Everything outside the plan, replaceable by the self-check.
    struct Env {
        var socket = VPNPaths.controlSocket
        var enabled: () -> Bool = { MainActor.assumeIsolated { EffectsPrefs.shared.lidAwake } }
        var power: () -> KeepAwakePlan.Power = { KeepAwake.readPower() }
        var heat: () -> LidAwakePlan.Heat = { LidAwakePlan.Heat(ProcessInfo.processInfo.thermalState) }
        var helper: () -> LidAwakePlan.Helper = { .missing }
        var buildsActive: () -> Bool = { false }
        var readFlag: @Sendable () -> Bool? = { SystemPmset.readFlag() }
        /// True when AppleClamshellState says closed; nil when it cannot be read.
        var lidClosed: () -> Bool? = { LidAwake.clamshellClosed() }
        var externalDisplay: () -> Bool = { LidAwake.hasExternalDisplay() }
        var sleepDisplay: () -> Void = { LidAwake.displaySleepNow() }
        var log: (String) -> Void = { noteBuildLog($0) }
        /// Real timers, the sleep/wake observers and the display sleep (off in the self-check).
        var live = true
    }

    @Published private(set) var status: LidAwakeStatus = .off(.off)
    var isActive: Bool { status == .active }

    var env: Env
    /// A preview's fixed state: nothing is asked of the helper and nothing is slept.
    private(set) var fixture: LidAwakeStatus?
    private var fixtureHelper: LidAwakePlan.Helper?
    /// A preview's fixed helper state (Setup shows it instead of the VPN store's).
    var helperOverride: LidAwakePlan.Helper? { fixtureHelper }

    private var latch = LidAwakePlan.Latch()
    private var lastWorking: Double?
    private var power = KeepAwakePlan.Power(onBattery: false, percent: nil)
    private var powerReadAt: Double = -1000
    /// The helper confirmed a held lease and it has not ended.
    private var leased = false
    private var lastSent: Double = -1000
    private var busy = false
    private var failedAt: Double?
    private var elsewhere = false
    private var renewals = 0
    private var lidHandled = false
    private var tick: Timer?
    private var lidTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastLogged = ""
    /// The time of the last evaluation: a reply is judged on the same clock as the request.
    private var clockNow: Double = 0
    private var stopped = false

    /// How often the app renews while the plan says hold (the helper's TTL is 90 s).
    static let renewEvery: Double = 30

    init(env: Env = Env()) {
        self.env = env
    }

    /// The helper as the Setup row sees it (a preview can fix it).
    func helperState() -> LidAwakePlan.Helper { fixtureHelper ?? env.helper() }

    // MARK: Fed by the store

    /// Called on every reload with whether any session works (builds count too).
    func update(working: Bool, now: Double) {
        if working || env.buildsActive() { lastWorking = now }
        evaluate(now: now)
    }

    /// The setting changed (Setup or the Machine panel).
    func settingChanged() { evaluate(now: Date().timeIntervalSince1970) }

    /// Someone is working now: seen within the last 15 s (the grace covers longer gaps).
    private func evaluate(now: Double) {
        guard fixture == nil else { return }
        clockNow = now
        let enabled = env.enabled()
        if enabled, now - powerReadAt >= 15 {
            power = env.power()
            powerReadAt = now
        }
        let working = lastWorking.map { now - $0 < 15 } ?? false
        var reason = LidAwakePlan.decide(.init(enabled: enabled, working: working, lastWorking: lastWorking, now: now,
                                               power: power, heat: env.heat(), helper: env.helper()), latch: &latch)
        var attempt = false
        if reason == nil {
            if let failedAt, now - failedAt < Self.renewEvery {
                // A recent refusal: shown, and not asked again until the retry time.
                reason = .helperFailed
            } else {
                attempt = true
                if elsewhere { reason = .managedElsewhere }
            }
        }
        if !enabled { elsewhere = false; failedAt = nil }
        drive(wanted: attempt, now: now)
        publish(reason: reason)
        retime(enabled: enabled)
    }

    private func publish(reason: LidAwakePlan.Reason?) {
        let next: LidAwakeStatus
        switch reason {
        case nil: next = leased ? .active : .armed
        case .noAgent: next = .armed
        case .some(let r): next = .off(r)
        }
        guard next != status else { return }
        status = next
        let line = next.logKind
        if line != lastLogged {
            lastLogged = line
            env.log("lid-awake: \(line)")
        }
    }

    // MARK: The helper

    private func drive(wanted: Bool, now: Double) {
        guard !busy else { return }
        if wanted {
            // Renewing: every 30 s. Not held yet: at once (5 s apart at most); 30 s apart once the
            // flag is known to be set by something else.
            let gap = leased || elsewhere ? Self.renewEvery : 5
            guard now - lastSent >= gap else { return }
            send(acquire: true, now: now)
        } else if leased {
            send(acquire: false, now: now)
        }
    }

    private func send(acquire: Bool, now: Double) {
        busy = true
        lastSent = now
        let request = VPNRequest(acquire ? .sleepLease : .sleepRelease)
        let socket = env.socket
        let readFlag = env.readFlag
        let verify = acquire && (!leased || renewals % 4 == 3)
        Task { [weak self] in
            let outcome = await VPNClient.send(request, socket: socket, timeout: 3)
            // The real flag, read back (no root needed), at the start of a lease and now and then.
            let flag: Bool? = verify ? await Task.detached { readFlag() }.value : nil
            self?.finish(acquire: acquire, outcome: outcome, flag: flag)
        }
    }

    private func finish(acquire: Bool, outcome: VPNClient.Outcome, flag: Bool?) {
        busy = false
        let now = clockNow
        switch outcome {
        case .reply(let reply) where reply.ok:
            if acquire {
                switch reply.sleep?.state {
                case .held:
                    failedAt = nil
                    elsewhere = false
                    renewals += 1
                    if flag == false {
                        // The helper says it holds the flag and the system says it does not.
                        leased = false
                        failedAt = now
                        env.log("lid-awake: the helper reports a lease but pmset shows SleepDisabled 0")
                    } else {
                        leased = true
                    }
                case .managedElsewhere:
                    leased = false
                    elsewhere = true
                default:
                    leased = false
                }
            } else {
                leased = false
                renewals = 0
            }
        case .reply, .failed:
            leased = false
            if acquire { failedAt = now }
        case .notRunning:
            leased = false
            if acquire { failedAt = now }
        }
        evaluate(now: now)
    }

    /// Lets go for good, as the app quits: the one place that waits for the helper (briefly).
    func stop() {
        stopped = true
        tick?.invalidate(); tick = nil
        lidTimer?.invalidate(); lidTimer = nil
        guard fixture == nil, leased else { return }
        leased = false
        _ = try? UnixSocket.exchange(env.socket, VPNWire.encode(VPNRequest(.sleepRelease)), timeout: 2)
    }

    // MARK: Timers, sleep and wake, the lid

    /// A 10 s heartbeat while the switch is on (renewals and the grace's end do not wait for a
    /// reload), a 2 s lid check only while active.
    private func retime(enabled: Bool) {
        guard env.live, !stopped else { return }
        if enabled, tick == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = Date().timeIntervalSince1970
                    if self.env.buildsActive() { self.lastWorking = now }
                    self.evaluate(now: now)
                }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            tick = timer
            observeSleep()
        } else if !enabled, tick != nil {
            tick?.invalidate(); tick = nil
        }
        if status == .active, lidTimer == nil {
            lidHandled = false
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkLid() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            lidTimer = timer
        } else if status != .active, lidTimer != nil {
            lidTimer?.invalidate(); lidTimer = nil
        }
    }

    /// With the lid shut and no external display, the built-in panel can stay lit under the lid:
    /// put the display to sleep, once per close.
    func checkLid() {
        guard status == .active, let closed = env.lidClosed() else { return }
        if !closed { lidHandled = false; return }
        if LidAwakePlan.shouldSleepDisplay(lidClosed: closed, externalDisplay: env.externalDisplay(), alreadyDone: lidHandled) {
            lidHandled = true
            env.log("lid-awake: lid closed, display put to sleep")
            env.sleepDisplay()
        }
    }

    private func observeSleep() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // Going to sleep: let the lease go (the helper's TTL ends it anyway if this is not heard).
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        // Back awake: decide again at once.
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastSent = -1000
                self.leased = false
                self.lidHandled = false
                if self.env.buildsActive() { self.lastWorking = Date().timeIntervalSince1970 }
                self.evaluate(now: Date().timeIntervalSince1970)
            }
        })
    }

    private func willSleep() {
        guard fixture == nil, leased else { return }
        leased = false
        busy = false
        Task { _ = await VPNClient.send(VPNRequest(.sleepRelease), socket: env.socket, timeout: 2) }
        publish(reason: .noAgent)
    }

    // MARK: System readings

    /// IOPMrootDomain's AppleClamshellState: true while the lid is shut.
    nonisolated static func clamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    /// Any active display that is not the built-in panel.
    nonisolated static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// `pmset displaysleepnow` needs no root.
    nonisolated static func displaySleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Previews

    /// `--preview --lid-fixture active|armed|battery|hot|helper-missing|helper-old|elsewhere|failed|off`:
    /// a fixed state for screenshots; nothing is asked of the helper.
    func applyFixture(_ name: String) {
        let table: [String: (LidAwakeStatus, LidAwakePlan.Helper)] = [
            "active": (.active, .ok), "armed": (.armed, .ok), "off": (.off(.off), .ok),
            "battery": (.off(.batteryLow), .ok), "hot": (.off(.hot), .ok),
            "helper-missing": (.off(.helperMissing), .missing), "helper-old": (.off(.helperOld), .old),
            "elsewhere": (.off(.managedElsewhere), .ok), "failed": (.off(.helperFailed), .ok),
        ]
        guard let (state, helper) = table[name] else { return }
        fixture = state
        fixtureHelper = helper
        status = state
    }
}

// MARK: The lid as a pure state machine for the self-check

/// `AINotch --awake-selfcheck`, the lid half: the plan on every reason, the hysteresis, and the
/// controller against a real helper protocol over a temp socket with a fake pmset.
enum LidAwakeSelfCheck {
    @MainActor
    static func run(_ check: (String, Bool) -> Void) {
        typealias Plan = LidAwakePlan
        let ac = KeepAwakePlan.Power(onBattery: false, percent: 80)
        func power(_ percent: Int, battery: Bool = true) -> KeepAwakePlan.Power { .init(onBattery: battery, percent: percent) }
        func decide(enabled: Bool = true, working: Bool = true, last: Double? = 1000, now: Double = 1000,
                    _ power: KeepAwakePlan.Power = KeepAwakePlan.Power(onBattery: false, percent: 80), heat: Plan.Heat = .nominal,
                    helper: Plan.Helper = .ok, latch: inout Plan.Latch) -> Plan.Reason? {
            Plan.decide(.init(enabled: enabled, working: working, lastWorking: last, now: now, power: power, heat: heat, helper: helper), latch: &latch)
        }
        var l = Plan.Latch()
        check("lid: working on AC holds", decide(ac, latch: &l) == nil)
        check("lid: switch off", decide(enabled: false, ac, latch: &l) == .off)
        check("lid: no agent, never worked: armed", decide(working: false, last: nil, ac, latch: &l) == .noAgent)
        check("lid: held through the grace", decide(working: false, last: 1000 - 119, ac, latch: &l) == nil)
        check("lid: armed after the grace", decide(working: false, last: 1000 - 121, ac, latch: &l) == .noAgent)
        check("lid: helper missing", decide(ac, helper: .missing, latch: &l) == .helperMissing)
        check("lid: helper old", decide(ac, helper: .old, latch: &l) == .helperOld)
        check("lid: helper missing outranks no agent", decide(working: false, last: nil, ac, helper: .missing, latch: &l) == .helperMissing)
        check("lid: off outranks the helper", decide(enabled: false, ac, helper: .missing, latch: &l) == .off)
        l = Plan.Latch()
        check("lid: on battery, 60% holds", decide(power(60), latch: &l) == nil)
        check("lid: battery 21% holds", decide(power(21), latch: &l) == nil)
        check("lid: battery 20% stops", decide(power(20), latch: &l) == .batteryLow)
        check("lid: battery 19% stops", decide(power(19), latch: &l) == .batteryLow)
        check("lid: back to 22% stays stopped (hysteresis)", decide(power(22), latch: &l) == .batteryLow)
        check("lid: 25% still stopped", decide(power(25), latch: &l) == .batteryLow)
        check("lid: 26% re-arms", decide(power(26), latch: &l) == nil)
        check("lid: then 24% holds again (no flap)", decide(power(24), latch: &l) == nil)
        _ = decide(power(10), latch: &l)
        check("lid: plugged in clears the lock at any charge", decide(power(10, battery: false), latch: &l) == nil)
        check("lid: unplugged again at 10% stops", decide(power(10), latch: &l) == .batteryLow)
        l = Plan.Latch()
        check("lid: battery 10% on AC holds", decide(power(10, battery: false), latch: &l) == nil)
        check("lid: unknown charge on battery holds", decide(KeepAwakePlan.Power(onBattery: true, percent: nil), latch: &l) == nil)
        l = Plan.Latch()
        check("lid: fair heat holds", decide(ac, heat: .fair, latch: &l) == nil)
        check("lid: serious heat stops", decide(now: 1000, ac, heat: .serious, latch: &l) == .hot)
        check("lid: critical heat stops", decide(now: 1001, ac, heat: .critical, latch: &l) == .hot)
        check("lid: a blip back to nominal stays stopped", decide(now: 1030, ac, heat: .nominal, latch: &l) == .hot)
        check("lid: 59 s after the last hot: stopped", decide(now: 1001 + 59, ac, heat: .fair, latch: &l) == .hot)
        check("lid: 60 s after: returns", decide(now: 1001 + 60, ac, heat: .fair, latch: &l) == nil)
        l = Plan.Latch()
        check("lid: hot while armed shows hot", decide(working: false, last: nil, ac, heat: .serious, latch: &l) == .hot)
        check("lid: lid display: closed, internal only, first time", Plan.shouldSleepDisplay(lidClosed: true, externalDisplay: false, alreadyDone: false))
        check("lid: lid display: not twice for one close", !Plan.shouldSleepDisplay(lidClosed: true, externalDisplay: false, alreadyDone: true))
        check("lid: lid display: not with an external display", !Plan.shouldSleepDisplay(lidClosed: true, externalDisplay: true, alreadyDone: false))
        check("lid: lid display: not with the lid open", !Plan.shouldSleepDisplay(lidClosed: false, externalDisplay: false, alreadyDone: false))
        check("lid: wing label says so, only when active", WingLabels.left(dots: [.idle], builds: 0, lidAwake: true) == "1 session: 1 idle. Staying awake with the lid closed."
              && WingLabels.left(dots: [.idle], builds: 0) == "1 session: 1 idle.")
        check("lid: status lines", LidAwakeStatus.active.line.hasPrefix("Active") && LidAwakeStatus.armed.line.hasPrefix("Armed")
              && LidAwakeStatus.off(.batteryLow).line.contains("20%") && LidAwakeStatus.off(.helperOld).line.contains("update"))

        // The controller against the real helper protocol, on a temp socket and a fake pmset.
        let dir = NSTemporaryDirectory() + "awake-lid-\(getpid())"
        mkdir(dir, 0o700)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socket = dir + "/s.sock"
        let pmset = FakePmset()
        let clock = Clock()
        let server = LeaseTestServer(path: socket, lease: SleepLease(runner: pmset, clock: { clock.now }, markerPath: dir + "/marker"), allowedUID: getuid())
        guard server.start() else { check("lid: temp helper socket", false); return }
        defer { server.stop() }
        var logs: [String] = []
        var env = LidAwake.Env()
        env.socket = socket
        env.live = false
        env.enabled = { true }
        env.helper = { .ok }
        env.power = { KeepAwakePlan.Power(onBattery: false, percent: 90) }
        env.heat = { .nominal }
        env.readFlag = { pmset.flag }
        env.log = { logs.append($0) }
        let controller = LidAwake(env: env)
        func settle(_ seconds: Double = 2) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, controller.busyForCheck { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let start = Date().timeIntervalSince1970
        controller.update(working: false, now: start)
        settle()
        check("lid e2e: switch on, nothing working: armed, flag off", controller.status == .armed && !pmset.flag && pmset.calls.isEmpty)
        controller.update(working: true, now: start + 1)
        settle()
        check("lid e2e: agent working: lease acquired, flag on, active", controller.status == .active && pmset.flag && pmset.calls.count == 1)
        controller.update(working: true, now: start + 20)
        settle()
        check("lid e2e: a reload before 30 s does not renew", pmset.calls.count == 1)
        clock.now += 30
        controller.update(working: true, now: start + 32)
        settle()
        check("lid e2e: renewed after 30 s, still on, no second pmset call", controller.status == .active && pmset.flag && pmset.calls.count == 1 && server.lease.status.state == .held)
        controller.update(working: false, now: start + 100)
        settle()
        check("lid e2e: agent stopped, inside the grace: still active", controller.status == .active && pmset.flag)
        controller.update(working: false, now: start + 32 + 121)
        settle()
        check("lid e2e: after the grace: released, flag off, armed", controller.status == .armed && !pmset.flag && pmset.calls.count == 2)
        // Expiry with the app gone.
        controller.update(working: true, now: start + 300)
        settle()
        check("lid e2e: working again: on", controller.status == .active && pmset.flag)
        let clockRef = clock
        check("lid e2e: the app silent for 91 s: the helper clears the flag", server.tick(after: 91, clock: clockRef) && !pmset.flag)
        // Battery low while holding.
        var batt = KeepAwakePlan.Power(onBattery: true, percent: 15)
        controller.env.power = { batt }
        controller.update(working: true, now: start + 320)
        settle()
        check("lid e2e: battery 15%: released and reported", controller.status == .off(.batteryLow) && !pmset.flag)
        // Quit releases.
        batt = KeepAwakePlan.Power(onBattery: false, percent: 90)
        controller.env.power = { batt }
        controller.update(working: true, now: start + 400)
        settle()
        check("lid e2e: on again", controller.status == .active && pmset.flag)
        controller.stop()
        check("lid e2e: quit releases the lease at once", !pmset.flag && server.lease.status.state == .idle)
        check("lid e2e: one log line per change, none for renewals", logs.filter { $0 == "lid-awake: active" }.count == 3 && logs.contains("lid-awake: armed") && logs.contains("lid-awake: off (batteryLow)"))
        // A flag set by hand.
        pmset.flag = true
        pmset.calls = []
        controller.env.power = { KeepAwakePlan.Power(onBattery: false, percent: 90) }
        controller.update(working: true, now: start + 500)
        settle()
        check("lid e2e: manual flag: reported as managed elsewhere, never touched", controller.status == .off(.managedElsewhere) && pmset.flag && pmset.calls.isEmpty)
        // A helper without the lease: status says old.
        var old = LidAwake.Env(); old.helper = { .old }; old.enabled = { true }; old.live = false; old.log = { _ in }
        let oldController = LidAwake(env: old)
        oldController.update(working: true, now: start)
        check("lid e2e: an old helper: update needed, nothing sent", oldController.status == .off(.helperOld))
        // The helper's own refusal: another user.
        server.allowedUID = getuid() &+ 1
        pmset.flag = false
        let refused = LidAwake(env: { var e = env; e.log = { _ in }; return e }())
        refused.update(working: true, now: start + 600)
        settle()
        check("lid e2e: a helper that refuses this user: not active, flag untouched", refused.status != .active && !pmset.flag)
    }

    /// A fake clock the helper side and the test share.
    final class Clock: @unchecked Sendable { var now = 1_000_000.0 }
}

/// The helper's request loop for the self-check: the same checks as the daemon (peer uid, the
/// request decoded, the two lease operations) on a temp socket, on its own queue.
final class LeaseTestServer: @unchecked Sendable {
    let path: String
    let lease: SleepLease
    var allowedUID: uid_t
    private let queue = DispatchQueue(label: "lease-test")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, lease: SleepLease, allowedUID: uid_t) {
        self.path = path
        self.lease = lease
        self.allowedUID = allowedUID
    }

    func start() -> Bool {
        guard let fd = try? UnixSocket.listen(path, mode: 0o600) else { return false }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            guard PeerCheck.allowed(peer: UnixSocket.peerUID(client), installedFor: allowedUID) else {
                try? UnixSocket.writeAll(client, VPNWire.encode(VPNReply.fail("This VPN helper serves another user.")))
                return
            }
            UnixSocket.setTimeout(client, seconds: 2)
            guard let line = try? UnixSocket.readLine(client, limit: VPNWire.maxRequest),
                  let request = VPNWire.decode(VPNRequest.self, line) else {
                try? UnixSocket.writeAll(client, VPNWire.encode(VPNReply.fail("The request could not be read.")))
                return
            }
            let reply: VPNReply
            switch request.op {
            case .sleepLease:
                if let why = lease.acquire() { reply = .fail(why) } else { reply = VPNReply(ok: true, sleep: lease.status) }
            case .sleepRelease:
                lease.release()
                reply = VPNReply(ok: true, sleep: lease.status)
            default:
                reply = .fail("not in this test")
            }
            try? UnixSocket.writeAll(client, VPNWire.encode(reply))
        }
        source.resume()
        self.source = source
        return true
    }

    /// Time passes for the helper side, and its tick runs, on its own queue.
    func tick(after seconds: Double, clock: LidAwakeSelfCheck.Clock) -> Bool {
        queue.sync {
            clock.now += seconds
            lease.tick()
        }
        return true
    }

    func stop() {
        source?.cancel()
        if listener >= 0 { close(listener) }
        unlink(path)
    }
}

extension LidAwake {
    /// For the self-check: a request is in flight.
    var busyForCheck: Bool { busy }
}
