import AVFoundation
import Foundation
import NotchCore

// `AINotch --sound-selfcheck`: the event sounds without playing any. All nine files are in the
// Sounds folder and decode, each shorter than 2.5 s; every event has its own file and priority;
// the collision rule (within 1.5 s the higher priority plays, a lower or equal one is dropped,
// after it anything plays); switches off (all, one) play nothing; the volume reaches the player;
// no sound for a session seen for the first time; one sound per transition; recoveries are not
// production alerts. A fake player records instead of playing. Exits 1 on any failure.
enum SoundSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--sound-selfcheck") else { return }
        exit(MainActor.assumeIsolated { run() })
    }

    @MainActor
    static func run() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(what)") }
        }

        // Files.
        expect(EventSound.allCases.count == 9, "nine events: \(EventSound.allCases.count)")
        expect(Set(EventSound.allCases.map(\.file)).count == EventSound.allCases.count, "every event has its own file")
        expect(Set(EventSound.allCases.map(\.priority)).count == EventSound.allCases.count, "every event has its own priority")
        expect(Set(EventSound.allCases.map(\.title)).count == EventSound.allCases.count, "every event has its own name")
        expect(NSSoundBackend.directory != nil, "the Sounds folder is found")
        var total = 0.0
        for event in EventSound.allCases {
            guard let url = NSSoundBackend.url(of: event), FileManager.default.fileExists(atPath: url.path) else {
                expect(false, "\(event.file).m4a is in the bundle")
                continue
            }
            do {
                let file = try AVAudioFile(forReading: url)
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                total += seconds
                expect(seconds > 0.3 && seconds < 2.5, "\(event.file) lasts \(String(format: "%.2f", seconds)) s")
            } catch {
                expect(false, "\(event.file).m4a decodes: \(error.localizedDescription)")
            }
        }
        print(String(format: "nine sounds, %.1f s in all", total))
        expect(FileManager.default.fileExists(atPath: (NSSoundBackend.directory?.path ?? "/nonexistent") + "/LICENSE-SOUNDS.txt"), "the licence note is beside the sounds")

        // Priority order from the brief.
        let order: [EventSound] = [.prodAlert, .needsInput, .failed, .trouble, .buildFailed, .contextFull, .prNews, .buildPassed, .finished]
        expect(order.map(\.priority) == order.map(\.priority).sorted(by: >), "priority: prod > needs input > failed > VPN/memory > build failed > context > PR > build passed > finished")
        expect(Set(order) == Set(EventSound.allCases), "the order names every event")

        // Player, with a fake backend, an own preferences store and a made-up clock.
        let suite = "ai-notch-sound-selfcheck-\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = SoundPrefs(defaults: defaults)
        var clock = 1000.0
        let fake = FakeSoundBackend()
        let player = SoundPlayer(backend: fake, prefs: prefs, clock: { clock })
        expect(prefs.master && EventSound.allCases.allSatisfy(prefs.isOn), "defaults: master and every event on")
        expect(abs(prefs.volume - SoundPrefs.defaultVolume) < 0.001, "default volume \(prefs.volume)")

        expect(player.play(.contextFull), "a sound plays when nothing is playing")
        expect(fake.played.last?.0 == .contextFull && abs(Double(fake.played.last?.1 ?? 0) - 0.6) < 0.001, "it plays at the set volume")
        clock += 0.5
        expect(!player.play(.contextFull), "the same event again within 1.5 s is dropped")
        expect(!player.play(.finished), "a lower one within 1.5 s is dropped")
        expect(fake.played.count == 1, "so far one sound: \(fake.played.count)")
        clock += 0.2
        expect(player.play(.needsInput), "a higher one within 1.5 s replaces it")
        expect(fake.played.count == 2 && fake.played.last?.0 == .needsInput, "and only it sounds now")
        clock += 0.3
        expect(!player.play(.failed), "a lower one than the one playing is dropped")
        clock += 2.0
        expect(player.play(.finished), "after 1.5 s anything plays")
        clock += 0.1
        expect(player.play(.prodAlert) && fake.played.last?.0 == .prodAlert, "a production alert beats everything")
        clock += 0.1
        expect(!player.play(.needsInput), "nothing beats it inside the window")
        // Each pair: the higher plays over the lower, never the lower over the higher.
        for (i, high) in order.enumerated() {
            for low in order.dropFirst(i + 1) {
                clock += 10
                _ = player.play(low)
                clock += 0.2
                let before = fake.played.count
                expect(player.play(high) && fake.played.count == before + 1, "\(high) replaces \(low)")
                clock += 10
                _ = player.play(high)
                clock += 0.2
                let kept = fake.played.count
                expect(!player.play(low) && fake.played.count == kept, "\(low) does not replace \(high)")
            }
        }

        // Switches.
        clock += 10
        prefs.set(.buildPassed, on: false)
        expect(!player.play(.buildPassed), "an event switched off plays nothing")
        expect(player.play(.buildFailed), "the others still play")
        clock += 10
        prefs.master = false
        let silent = fake.played.count
        expect(!EventSound.allCases.contains { player.play($0) } && fake.played.count == silent, "master off: nothing plays")
        expect(player.replacesSystemSound == false, "master off: notifications keep their own sound")
        player.preview(.finished)
        expect(fake.played.count == silent + 1, "the ▶ plays even with the switches off")
        prefs.master = true
        expect(player.replacesSystemSound, "master on: notifications are silent, the app's sound plays")
        let reread = SoundPrefs(defaults: defaults)
        expect(reread.master && !reread.isOn(.buildPassed) && reread.isOn(.finished), "the switches persist (effects.sounds, sound.<event>)")
        expect(defaults.object(forKey: "sound.buildPassed") as? Bool == false, "key sound.<event>")
        prefs.volume = 0.25
        clock += 10
        _ = player.play(.finished)
        expect(abs(Double(fake.played.last?.1 ?? 0) - 0.25) < 0.001, "the volume change reaches the player")

        // Transitions.
        let after = 20.0
        func cue(_ before: Phase?, _ now: Phase, took: Double = 30) -> EventSound? {
            SoundCues.session(before: before, now: now, tookSeconds: took, soundAfterTurn: after)
        }
        expect(cue(nil, .waiting) == nil && cue(nil, .idle) == nil && cue(nil, .working) == nil, "no sound for a session seen for the first time")
        expect(cue(.working, .waiting) == .needsInput && cue(.idle, .waiting) == .needsInput, "waiting: needs you")
        expect(cue(.waiting, .waiting) == nil, "no change, no sound (once per transition)")
        expect(cue(.working, .idle, took: 30) == .finished, "a 30 s turn finishing sounds")
        expect(cue(.working, .idle, took: 5) == nil, "a 5 s turn does not")
        expect(cue(.waiting, .idle) == nil && cue(.idle, .working) == nil, "waiting→idle and idle→working are silent")

        // Production alerts: recoveries are good news.
        let bad = ProdAlertEvent.Kind.allCases.filter(\.isBad)
        expect(!ProdAlertEvent.Kind.monitorRecovered.isBad && !ProdAlertEvent.Kind.incidentResolved.isBad && !ProdAlertEvent.Kind.metricNormal.isBad, "recoveries are not alerts")
        expect(bad.contains(.monitorAlert) && bad.contains(.incidentDeclared) && bad.contains(.watchdogStory) && bad.contains(.metricOver), "alerts, incidents, numbers and Watchdog are")

        print("sound selfcheck: \(checks - failures)/\(checks) ok")
        return failures == 0 ? 0 : 1
    }
}
