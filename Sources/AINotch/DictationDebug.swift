import AVFoundation
import AppKit
import DictationCore
import Foundation
import Speech

// Dev entry points for dictation, never the app (see scripts/dev/README.md):
//   AINotch --dictation-transcribe <audio file> [--locale en-IN]
//       the file through the same AudioPump and SpeechAnalyzer path the microphone uses; prints
//       the raw transcript and the rule-cleaned one.
//   AINotch --dictation-clean "<text>" --endpoint <url> [--style keep|english] [--app <name>]
//       the Claude call against a stub server with a made-up key; prints what came back.
//   AINotch --dictation-inject "<raw text>" [--after <s>] [--endpoint <url>]
//       the whole path after speech-to-text (rules, Claude when a key is saved, paste, pill) into
//       the app in front after a delay, then exits; prints the final text's length, not the text.
//   AINotch --dictation-live-test <seconds>
//       what a Fn press does, in this process: the real microphone, the real controller (beginRecording,
//       finishRecording, the speech session, the pill), nothing inserted. Prints each phase and the raw
//       transcript. Start it as `open -W -n -a AINotch.app --stdout out.txt --args --dictation-live-test 6`
//       so the Microphone permission is the app's own; play `say` through the speakers meanwhile.
//   AINotch --dictation-pill
//       the pill in each state, three seconds each, with a made-up level.
enum DictationDebug {
    static func runIfAsked(_ args: [String]) {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let file = value("--dictation-transcribe") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await transcribeFile(file, locale: value("--locale") ?? "en-IN")
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let text = value("--dictation-clean") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                let endpoint = value("--endpoint").flatMap(URL.init(string:)) ?? CleanupPrompt.endpoint
                let style = DictationStyle(rawValue: value("--style") ?? "keep") ?? .keepMyWords
                let app = value("--app")
                let rules = RuleCleaner.clean(text, style: style)
                let result = await ClaudeCleanup(endpoint: endpoint).clean(transcript: rules, fallback: rules, apiKey: "sk-test-fake", style: style,
                                                                           context: AppContext.of(appName: app), appName: app)
                print("rules:    \(rules)")
                print("usedAI:   \(result.usedAI)")
                print("failure:  \(result.failure ?? "none")")
                print("result:   \(result.text)")
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let raw = value("--dictation-inject") {
            let after = Double(value("--after") ?? "3") ?? 3
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let dictation = Dictation.shared
                dictation.endpointOverride = value("--endpoint").flatMap(URL.init(string:))
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    MainActor.assumeIsolated {
                        let front = NSWorkspace.shared.frontmostApplication
                        FileHandle.standardError.write(Data("injecting into \(front?.localizedName ?? "?"); accessibility \(AXIsProcessTrusted()); secure input \(DictationInsert.secureInputOn)\n".utf8))
                        Task { @MainActor in
                            let text = await dictation.finalText(raw: raw, app: (front?.localizedName, front?.bundleIdentifier))
                            FileHandle.standardError.write(Data("final text: \(text.count) characters\n".utf8))
                            await dictation.insertAndReport(text)
                            try? await Task.sleep(for: .seconds(1.5))
                            exit(0)
                        }
                    }
                }
                app.run()
            }
        }
        if args.contains("--dictation-assets") {
            // Asset state in this app's identity; `--release` gives the reserved languages back first.
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                if #available(macOS 26.0, *) {
                    if args.contains("--release") { for l in await AssetInventory.reservedLocales { _ = await AssetInventory.release(reservedLocale: l) } }
                    let l = Locale(identifier: value("--locale") ?? "en-IN")
                    let m = SpeechTranscriber(locale: l, preset: .transcription)
                    print("reserved: \(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) })")
                    print("status:   \(await AssetInventory.status(forModules: [m]))")
                    print("installedLocales has it: \(await SpeechDictation.isInstalled(l))")
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let seconds = value("--dictation-live-test").flatMap(Double.init) {
            MainActor.assumeIsolated { runLiveTest(seconds: seconds) }
        }
        if args.contains("--dictation-pill") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let pill = DictationPill()
                let steps: [(DictationPhase, Double)] = [
                    (.listening(since: Date()), 4), (.downloading, 2), (.transcribing, 2), (.cleaning, 2), (.inserted, 2), (.copied, 2),
                    (.message("Secure field"), 2), (.message("Needs macOS 26"), 2),
                ]
                var at = 0.5
                for (phase, seconds) in steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { pill.show(phase) } }
                    at += seconds
                }
                // A made-up speech level while listening.
                var t = 0.0
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    MainActor.assumeIsolated { t += 0.05; pill.model.push(level: Float(0.15 + 0.6 * abs(sin(t * 7)) * abs(sin(t * 2.3)))) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + at + 1) { exit(0) }
                app.run()
            }
        }
    }

    @MainActor
    static func runLiveTest(seconds: Double) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dictation = Dictation.shared
        func say(_ line: String) { print(line); fflush(stdout) }
        var finished = false
        var raw: String?
        dictation.liveTestCapture = { raw = $0 }
        let phases = dictation.$phase.sink { say("phase: \($0)") }
        say("locale: \(dictation.prefs.locale); mic status: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        Task { @MainActor in
            _ = await DictationPermissions.shared.requestMicrophone()
            dictation.beginRecording()
            try? await Task.sleep(for: .seconds(seconds))
            dictation.finishRecording()
            // Until the controller is back to idle (or a message has shown), at most 60 seconds.
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(100))
                if case .listening = dictation.phase { continue }
                if case .transcribing = dictation.phase { continue }
                if case .cleaning = dictation.phase { continue }
                break
            }
            try? await Task.sleep(for: .milliseconds(300))
            say("raw: \(raw ?? "(none)")")
            say("note: \(dictation.lastNote ?? "none")")
            finished = true
            _ = phases
            exit(finished ? 0 : 1)
        }
        app.run()
    }

    static func transcribeFile(_ path: String, locale: String) async {
        guard #available(macOS 26.0, *) else { print("needs macOS 26"); return }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let pump = AudioPump()
            let session = try await SpeechDictation.start(localeIdentifier: locale, source: file.processingFormat, pump: pump)
            let chunk: AVAudioFrameCount = 4096
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                try file.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                pump.feed(buffer)
            }
            let raw = try await session.finish()
            if CommandLine.arguments.contains("--dictation-trace") { FileHandle.standardError.write(Data("fed \(pump.frames) frames at target rate\n".utf8)) }
            print("locale:  \(locale)")
            print("raw:     \(raw)")
            print("rules:   \(RuleCleaner.clean(raw))")
        } catch {
            print("failed: \(error)")
        }
    }
}
