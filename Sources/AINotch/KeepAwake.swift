import Foundation
import IOKit.pwr_mgt
import IOKit.ps

// Keeps the Mac from sleeping on its own while an agent works, so a long turn goes on with the
// screen locked or the display asleep. One IOKit power assertion (the display may still sleep and
// the screen may still lock), held while any session works and for a couple of minutes after the
// last one stops. A closed lid is out of reach: macOS sleeps then, unless a display is attached.

/// When the assertion should be held. Pure, so the self-check can run it on made-up inputs.
enum KeepAwakePlan {
    /// How long the assertion outlives the last working session: a short gap between turns
    /// must not let the Mac sleep.
    static let grace: Double = 120
    /// On battery, below this charge (percent) it lets go.
    static let lowBattery = 20

    struct Power: Equatable {
        var onBattery: Bool
        /// Percent charged; nil when there is no battery or it cannot be read.
        var percent: Int?
    }

    /// `lastWorking` is when a session was last seen working; nil when none has been.
    static func wants(enabled: Bool, onBatteryAllowed: Bool, working: Bool, lastWorking: Double?, now: Double, power: Power) -> Bool {
        guard enabled else { return false }
        guard working || lastWorking.map({ now - $0 < grace }) == true else { return false }
        guard power.onBattery else { return true }
        guard onBatteryAllowed else { return false }
        return (power.percent ?? 100) >= lowBattery
    }
}

/// Holds and releases the assertion as the plan says. Fed from the store's reload; it touches
/// IOKit only when the answer changes.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    /// What `pmset -g assertions` shows.
    nonisolated static let assertionName = "AI Notch: an agent is working"

    private var assertion: IOPMAssertionID = 0
    private var holding = false
    private var lastWorking: Double?
    /// The battery is read at most this often, and only while the assertion could be wanted.
    private var power = KeepAwakePlan.Power(onBattery: false, percent: nil)
    private var powerReadAt: Double = 0

    var isHolding: Bool { holding }

    /// Called on every reload with whether any session works.
    func update(working: Bool, now: Double, enabled: Bool? = nil, onBattery: Bool? = nil) {
        let enabled = enabled ?? EffectsPrefs.shared.keepAwake
        let onBattery = onBattery ?? EffectsPrefs.shared.keepAwakeOnBattery
        if working { lastWorking = now }
        let recent = working || lastWorking.map { now - $0 < KeepAwakePlan.grace } == true
        if enabled, recent, now - powerReadAt >= 15 {
            power = Self.readPower()
            powerReadAt = now
        }
        let wanted = KeepAwakePlan.wants(enabled: enabled, onBatteryAllowed: onBattery,
                                         working: working, lastWorking: lastWorking, now: now, power: power)
        apply(wanted)
    }

    /// Lets go for good, as the app quits.
    func stop() { apply(false) }

    private func apply(_ wanted: Bool) {
        guard wanted != holding else { return }
        if wanted {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     Self.assertionName as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
                holding = true
            }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            holding = false
        }
    }

    /// Whether the Mac runs on its battery, and how full it is.
    static func readPower() -> KeepAwakePlan.Power {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return KeepAwakePlan.Power(onBattery: false, percent: nil)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let percent = current.flatMap { c in maximum.map { m in m > 0 ? c * 100 / m : c } }
            return KeepAwakePlan.Power(onBattery: onBattery, percent: percent)
        }
        return KeepAwakePlan.Power(onBattery: false, percent: nil)
    }
}

/// `AINotch --awake-selfcheck`: the plan on made-up inputs, then a real assertion made, seen in
/// the system's list under its name and released; and the zombie test the session grace uses.
/// Exits 1 on any failure.
enum KeepAwakeSelfCheck {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let ac = KeepAwakePlan.Power(onBattery: false, percent: 80)
        let battery = KeepAwakePlan.Power(onBattery: true, percent: 60)
        let low = KeepAwakePlan.Power(onBattery: true, percent: 19)
        func wants(enabled: Bool = true, battery allowed: Bool = true, working: Bool, last: Double?, now: Double = 1000, _ power: KeepAwakePlan.Power) -> Bool {
            KeepAwakePlan.wants(enabled: enabled, onBatteryAllowed: allowed, working: working, lastWorking: last, now: now, power: power)
        }
        check("working holds it", wants(working: true, last: 1000, ac))
        check("never worked: not held", !wants(working: false, last: nil, ac))
        check("held through the grace", wants(working: false, last: 1000 - 119, ac))
        check("released after the grace", !wants(working: false, last: 1000 - 121, ac))
        check("setting off: not held", !wants(enabled: false, working: true, last: 1000, ac))
        check("on battery, allowed", wants(working: true, last: 1000, battery))
        check("on battery, not allowed", !wants(battery: false, working: true, last: 1000, battery))
        check("on battery below 20%", !wants(working: true, last: 1000, low))
        check("below 20% but on power", wants(working: true, last: 1000, KeepAwakePlan.Power(onBattery: false, percent: 10)))

        let awake = KeepAwake()
        let start = Date().timeIntervalSince1970
        awake.update(working: true, now: start, enabled: true, onBattery: true)
        check("working: assertion made", awake.isHolding && Self.listed())
        awake.update(working: false, now: start + 60, enabled: true, onBattery: true)
        check("60 s after: still held", awake.isHolding && Self.listed())
        awake.update(working: false, now: start + 121, enabled: true, onBattery: true)
        check("121 s after: released", !awake.isHolding && !Self.listed())
        awake.update(working: true, now: start + 200, enabled: true, onBattery: true)
        awake.stop()
        check("stop releases it", !awake.isHolding && !Self.listed())

        // The setting turned off in the middle of the grace lets go at once.
        awake.update(working: true, now: start + 300, enabled: true, onBattery: true)
        awake.update(working: false, now: start + 330, enabled: true, onBattery: true)
        check("30 s into the grace: held", awake.isHolding && Self.listed())
        awake.update(working: false, now: start + 331, enabled: false, onBattery: true)
        check("setting off mid-grace: released", !awake.isHolding && !Self.listed())
        awake.update(working: false, now: start + 332, enabled: true, onBattery: true)
        check("setting back on in the grace: held again", awake.isHolding && Self.listed())
        awake.stop()

        // A process that has exited but not been collected still answers kill(pid, 0); it is told apart.
        var child: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("true"), nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&child, "/usr/bin/true", nil, nil, &argv, nil) == 0
        usleep(500_000)
        check("a finished, uncollected child is a zombie that kill() still sees", spawned && kill(child, 0) == 0 && ProcessList.isZombie(child))
        check("this process is not a zombie", !ProcessList.isZombie(getpid()))
        check("launchd (unreadable by pid info) is not a zombie", !ProcessList.isZombie(1))
        if spawned { var status: Int32 = 0; waitpid(child, &status, 0) }
        print(failures == 0 ? "all passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }

    /// Whether this process holds an assertion with the name, by the system's own list.
    private static func listed() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [Int: [[String: Any]]] else { return false }
        return (all[Int(getpid())] ?? []).contains { $0[kIOPMAssertionNameKey as String] as? String == KeepAwake.assertionName }
    }
}
