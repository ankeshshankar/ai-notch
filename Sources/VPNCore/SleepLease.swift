import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The helper's "sleep-disable lease": while the app keeps renewing it, the helper holds the
// system's SleepDisabled flag (`pmset -a disablesleep 1`), so an Apple-silicon MacBook stays
// awake with the lid closed; the moment the lease ends (release, expiry, the helper stopping or
// starting, an uninstall) the helper runs `pmset -a disablesleep 0`.
//
// Why it is safe to ask a root helper for this:
//   - Two requests only (`sleep-lease`, `sleep-release`), neither takes an argument. The only
//     commands ever run are the two fixed argument arrays below, by absolute path, no shell.
//   - The lease is short (90 s) and only the app's renewals keep it alive: if the app dies, is
//     killed or the Mac loses it, the flag is cleared by the helper itself.
//   - The helper clears only what it set: a marker file in its root-owned folder says "I set it".
//     If the flag was already on when the helper first saw it (the owner set it by hand), the
//     helper leaves it alone and reports "managed elsewhere".

public enum SleepLeaseBuild {
    /// The lease protocol the helper speaks; a helper without it answers neither request.
    public static let proto = 1
    /// How long one acquire or renew holds the flag.
    public static let ttl: Double = 90
}

public struct SleepStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The helper holds the flag on a live lease.
        case held
        /// The helper holds nothing.
        case idle
        /// The flag was on before the helper set it (set by hand or by another tool): not touched.
        case managedElsewhere
    }

    public var state: State
    /// Seconds left on the lease while held.
    public var expiresIn: Double?

    public init(state: State, expiresIn: Double? = nil) {
        self.state = state
        self.expiresIn = expiresIn
    }
}

/// Runs and reads `pmset`; injectable so the lease can be exercised without root.
public protocol PmsetRunning: AnyObject {
    /// Sets or clears the SleepDisabled flag; true when pmset exited 0.
    func setSleepDisabled(_ on: Bool) -> Bool
    /// The flag as `pmset -g` shows it; nil when it cannot be read.
    func sleepDisabled() -> Bool?
}

public final class SystemPmset: PmsetRunning {
    public static let path = "/usr/bin/pmset"

    public init() {}

    /// The fixed argument arrays: nothing here comes from a request.
    public static func arguments(on: Bool) -> [String] { ["-a", "disablesleep", on ? "1" : "0"] }

    public func setSleepDisabled(_ on: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.path)
        process.arguments = Self.arguments(on: on)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public func sleepDisabled() -> Bool? { Self.readFlag() }

    /// `pmset -g` needs no root.
    public static func readFlag() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-g"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The SleepDisabled line of `pmset -g`, e.g. "SleepDisabled\t\t1"; absent means off.
    public static func parse(_ text: String) -> Bool? {
        guard !text.isEmpty else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }
}

/// The lease. Not thread-safe: the caller runs it on one queue.
public final class SleepLease {
    private let runner: PmsetRunning
    private let clock: () -> Double
    private let markerPath: String
    /// The helper has set the flag and not yet cleared it (mirrors the marker file).
    private var owned = false
    private var expiresAt: Double?
    private var elsewhere = false
    private var lastClearAttempt: Double = 0

    public init(runner: PmsetRunning, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }, markerPath: String) {
        self.runner = runner
        self.clock = clock
        self.markerPath = markerPath
    }

    public var status: SleepStatus {
        if owned, let expiresAt { return SleepStatus(state: .held, expiresIn: max(0, expiresAt - clock())) }
        return SleepStatus(state: elsewhere ? .managedElsewhere : .idle)
    }

    /// At the helper's start: a marker left by a helper that died with the flag set means the flag
    /// is ours and stale, so it is cleared. No marker: whatever the flag is, it is not ours.
    public func start() {
        if FileManager.default.fileExists(atPath: markerPath) {
            owned = true
            clear()
        }
    }

    /// Acquire or renew. Nil on success (read `status`), else why not.
    public func acquire() -> String? {
        let now = clock()
        if owned {
            // Renewal. If something cleared the flag meanwhile, set it again.
            if runner.sleepDisabled() == false, !runner.setSleepDisabled(true) { return "pmset could not set the flag." }
            expiresAt = now + SleepLeaseBuild.ttl
            return nil
        }
        if runner.sleepDisabled() == true {
            // Already on and not by us: leave it, and never clear it.
            elsewhere = true
            expiresAt = nil
            return nil
        }
        elsewhere = false
        // The marker first: a crash between the marker and pmset leaves a marker (cleared at the
        // next start), never a flag nobody knows about.
        guard writeMarker() else { return "The helper could not write its marker." }
        guard runner.setSleepDisabled(true) else {
            removeMarker()
            return "pmset could not set the flag."
        }
        owned = true
        expiresAt = now + SleepLeaseBuild.ttl
        return nil
    }

    /// The app lets go.
    public func release() {
        elsewhere = false
        expiresAt = nil
        if owned { clear() }
    }

    /// Called every few seconds by the helper: ends an expired lease, retries a failed clear.
    public func tick() {
        guard owned else { return }
        let now = clock()
        if let expiresAt, now < expiresAt { return }
        // A failed clear is retried at most every 15 s.
        if now - lastClearAttempt >= 15 { clear() }
    }

    /// The helper stops, or is uninstalled.
    public func shutdown() {
        expiresAt = nil
        if owned { clear() }
    }

    private func clear() {
        lastClearAttempt = clock()
        guard runner.setSleepDisabled(false) else { return }
        owned = false
        expiresAt = nil
        removeMarker()
    }

    private func writeMarker() -> Bool {
        let fd = open(markerPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let text = "set by ai-notch-vpnd at \(Int(clock()))\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        return true
    }

    private func removeMarker() { unlink(markerPath) }

    /// Uninstall: clears the flag when the marker says the helper set it, then removes the marker.
    public static func cleanup(runner: PmsetRunning, markerPath: String) {
        if FileManager.default.fileExists(atPath: markerPath) {
            guard runner.setSleepDisabled(false) else { return }
        }
        unlink(markerPath)
    }
}

/// Who may talk to the helper: root, and the user it was installed for.
public enum PeerCheck {
    public static func allowed(peer: uid_t?, installedFor: uid_t) -> Bool {
        guard let peer else { return false }
        return peer == 0 || peer == installedFor
    }
}

/// A pmset that touches nothing: the flag in memory and every call recorded. For the self-checks.
public final class FakePmset: PmsetRunning {
    public var flag: Bool
    /// The argument arrays of every set call, in order.
    public var calls: [[String]] = []
    public var failSet = false
    public var unreadable = false

    public init(flag: Bool = false) { self.flag = flag }

    public func setSleepDisabled(_ on: Bool) -> Bool {
        calls.append(SystemPmset.arguments(on: on))
        if failSet { return false }
        flag = on
        return true
    }

    public func sleepDisabled() -> Bool? { unreadable ? nil : flag }
}
