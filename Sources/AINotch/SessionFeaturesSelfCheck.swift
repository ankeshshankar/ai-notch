import Foundation
import NotchCore

// `AINotch --session-selfcheck`: the per-session row features on made-up inputs: the context reading
// and its levels, the failure reasons and state, the git status parse and marks, and the CI match.
// No UI, no network. Exits 1 on any failure.

enum SessionFeaturesSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--session-selfcheck") else { return }
        let code = run()
        // `--session-selfcheck <transcript>`: also reads that transcript's last 64 KB as the app does, numbers only.
        if let index = arguments.firstIndex(of: "--session-selfcheck"), index + 1 < arguments.count,
           let handle = FileHandle(forReadingAtPath: arguments[index + 1]) {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            if let reading = ContextUse.reading(inTail: text) {
                let window = ContextUse.window(model: nil, observed: reading.tokens)
                print("real transcript: tokens \(reading.tokens), window \(window), \(ContextUse.percent(tokens: reading.tokens, window: window))%, level \(ContextUse.level(tokens: reading.tokens, point: ContextUse.compactPoint(window: window)))")
            } else {
                print("real transcript: no reading")
            }
        }
        exit(code)
    }

    static func reply(_ input: Int, create: Int = 0, read: Int = 0, model: String = "claude-opus-4-7", side: Bool = false, at: String = "2026-11-11T10:00:00.000Z") -> String {
        "{\"type\":\"assistant\",\"isSidechain\":\(side),\"timestamp\":\"\(at)\",\"message\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(create),\"cache_read_input_tokens\":\(read),\"output_tokens\":9}}}"
    }

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL \(what)") }
        }

        // Row order: fixed; activity moves nothing.
        func row(_ id: String, _ phase: Phase, start: Double, updated: Double, waitSince: Double? = nil) -> SessionState {
            var r = SessionState(id: id, cwd: "/tmp/x", now: start)
            r.phase = phase; r.updatedAt = updated; r.waitingSince = waitSince
            if phase == .waiting { r.waitingFor = "approval" }
            return r
        }
        func ids(_ list: [SessionState]) -> String { list.sorted(by: SessionOrder.before).map(\.id).joined(separator: ",") }
        expect(ids([row("a", .working, start: 10, updated: 500), row("b", .working, start: 20, updated: 100)]) == ids([row("a", .working, start: 10, updated: 100), row("b", .working, start: 20, updated: 900)]), "order: two working rows do not swap on events")
        expect(ids([row("a", .working, start: 10, updated: 1), row("b", .idle, start: 20, updated: 2)]) == ids([row("a", .idle, start: 10, updated: 3), row("b", .working, start: 20, updated: 4)]), "order: working <-> idle does not move")
        let w1 = row("a", .waiting, start: 10, updated: 900, waitSince: 100), w2 = row("b", .waiting, start: 20, updated: 100, waitSince: 200)
        expect(ids([w2, w1]) == "a,b" && ids([w1, w2]) == "a,b", "order: first waiting stays first, whatever the events")
        var w2e = w2; w2e.updatedAt = 5000
        expect(ids([w1, w2e]) == "a,b", "order: events on the later waiting row do not lift it")
        expect(ids([row("a", .working, start: 10, updated: 1), row("b", .working, start: 20, updated: 1), w2]).hasPrefix("b,"), "order: a waiting row goes on top")
        expect(ids([row("a", .waiting, start: 10, updated: 1, waitSince: 50), row("b", .working, start: 20, updated: 1)]) == "a,b" && ids([row("a", .working, start: 10, updated: 2), row("b", .working, start: 20, updated: 1)]) == "b,a", "order: answered returns to its fixed slot")
        var failedRow = row("c", .idle, start: 5, updated: 5); failedRow.failure = "overloaded"; failedRow.failedAt = 300
        expect(ids([row("a", .working, start: 10, updated: 1), failedRow]).hasPrefix("c,"), "order: failed is with the ones that need you")
        expect(ids([row("b", .working, start: 10, updated: 1), row("a", .working, start: 10, updated: 1)]) == "a,b", "order: same start, id breaks the tie")

        // Context reading.
        expect(ContextUse.reading(inTail: reply(10, create: 20, read: 30))?.tokens == 60, "sums the three fields")
        expect(ContextUse.reading(inTail: reply(1, read: 5) + "\n" + reply(10, read: 90))?.tokens == 100, "newest reply wins")
        expect(ContextUse.reading(inTail: reply(10, read: 90) + "\n" + reply(500_000, side: true))?.tokens == 100, "sidechain ignored")
        expect(ContextUse.reading(inTail: reply(10, read: 90) + "\n{\"type\":\"user\"}\n{ broken")?.tokens == 100, "odd lines skipped")
        expect(ContextUse.reading(inTail: "") == nil, "empty tail")
        expect(ContextUse.reading(inTail: "{\"type\":\"assistant\",\"message\":{\"model\":\"x\"}}") == nil, "missing usage")
        expect(ContextUse.reading(inTail: "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":\"7\"}}}") == nil, "string tokens")
        expect(ContextUse.reading(inTail: "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":-4}}}") == nil, "negative tokens")
        expect(ContextUse.reading(inTail: "{\"type\":\"assistant\",\"message\":{\"usage\":{\"cache_read_input_tokens\":4}}}") == nil, "no input_tokens")
        expect(ContextUse.reading(inTail: reply(10, read: 90, model: "<synthetic>").replacingOccurrences(of: "claude-opus-4-7", with: "<synthetic>")) == nil, "synthetic reply skipped")
        let boundary = "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"2026-11-11T10:05:00.000Z\",\"compactMetadata\":{\"postTokens\":12000}}"
        expect(ContextUse.reading(inTail: reply(10, read: 150_000) + "\n" + boundary)?.tokens == 12_000, "compaction boundary after reply")
        expect(ContextUse.reading(inTail: boundary + "\n" + reply(10, read: 15_000, at: "2026-11-11T10:06:00.000Z"))?.tokens == 15_010, "reply after boundary")
        let old = ContextUse.reading(inTail: reply(10, read: 150_000))
        expect(old?.valid(after: nil) != nil, "reading valid without compaction")
        let compacted = ISO8601DateFormatter().date(from: "2026-11-11T10:30:00Z")!.timeIntervalSince1970
        expect(old?.valid(after: compacted) == nil, "reading before compaction dropped")
        expect(ContextUse.reading(inTail: reply(10, read: 15_000, at: "2026-11-11T10:31:00.000Z"))?.valid(after: compacted) != nil, "reading after compaction kept")

        // Window, point, level, percent.
        for (model, wide) in [("claude-fable-1", true), ("claude-sonnet-5-5", true), ("claude-haiku-5-5", true), ("claude-opus-4-7", true), ("claude-opus-4-6", false),
                              ("claude-sonnet-4-6", false), ("claude-haiku-4-5", false), ("claude-opus-4-6[1m]", true), ("claude-sonnet-4-6[1m]", true)] {
            expect(ContextUse.window(model: model, observed: 1000) == (wide ? 1_000_000 : 200_000), "window \(model)")
        }
        expect(ContextUse.window(model: "claude-opus-4-6", observed: 250_000) == 1_000_000, "over 200K means 1M")
        expect(ContextUse.window(model: nil, observed: 10) == 200_000, "no model is 200K")
        expect(ContextUse.window(model: "claude-opus-4-7", observed: 10, env: AutoCompactEnv(no1M: true)) == 200_000, "1M switched off")
        expect(ContextUse.compactPoint(window: 1_000_000) == 967_000, "1M compact point")
        expect(ContextUse.compactPoint(window: 200_000) == 200_000, "200K compact point")
        expect(ContextUse.compactPoint(window: 200_000, env: AutoCompactEnv(pct: 50)) == 100_000, "pct override")
        expect(ContextUse.compactPoint(window: 200_000, env: AutoCompactEnv(pct: 100, window: 150_000)) == 150_000, "window override")
        expect(AutoCompactEnv.read(["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "80"])?.pct == 80, "env pct read")
        expect(AutoCompactEnv.read(["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "abc"]) == nil, "env odd ignored")
        expect(AutoCompactEnv.read([:]) == nil, "env empty is nil")
        expect(ContextUse.level(tokens: 100_000, point: 200_000) == .normal, "50% normal")
        expect(ContextUse.level(tokens: 160_000, point: 200_000) == .warn, "80% warn")
        expect(ContextUse.level(tokens: 184_000, point: 200_000) == .strong, "92% strong")
        expect(ContextUse.level(tokens: 800_000, point: 967_000) == .warn, "1M 83% warn")
        expect(ContextUse.percent(tokens: 50_000, window: 200_000) == 25, "percent")
        expect(ContextUse.percent(tokens: 5, window: 0) == 0, "percent without window")

        // Alert fires once per crossing.
        var alerted = false, fired = 0
        for level in [ContextLevel.normal, .warn, .strong, .strong, .strong, .warn, .strong, .normal, .strong, .strong] {
            let step = ContextUse.alertStep(level: level, alerted: alerted)
            if step.fire { fired += 1 }
            alerted = step.alerted
        }
        expect(fired == 2, "alert fires once per crossing (got \(fired))")

        // Session state.
        var s = SessionState(id: "t-a", cwd: "/tmp/x", now: 100)
        s.contextTokens = 190_000; s.contextWindow = 200_000
        expect(s.contextPercent == 95 && s.contextLevel == .strong, "session context strong")
        s.contextTokens = nil
        expect(s.contextPercent == nil && s.contextLevel == .normal, "no tokens shows nothing")
        s.phase = .idle; s.failure = "rate_limit"
        expect(s.isFailed && s.failureText == "Rate limited", "failed idle")
        s.phase = .working
        expect(!s.isFailed, "working again is not failed")
        s.compactingSince = 1000
        expect(s.isCompacting(at: 1100) && !s.isCompacting(at: 1000 + 1801), "compacting expires")
        for (code, text) in [("rate_limit", "Rate limited"), ("overloaded", "Overloaded"), ("authentication_failed", "Sign-in failed"), ("billing_error", "Billing problem"),
                             ("server_error", "Server error"), ("max_output_tokens", "Output limit hit"), ("weird", "Failed"), ("", "Failed")] {
            expect(FailureReason.text(code) == text, "reason \(code)")
        }
        expect(FailureReason.text(nil) == "Failed", "reason nil")

        // Dot and wing priority.
        var failed = CollapsedStripSelfCheck.session("f", .idle)
        failed.failure = "overloaded"
        expect(StripDots.state(of: failed, now: 1_000) == .failed, "failed dot")
        expect(WingSlot.pick(waiting: 1, sessionFailures: 1, justDone: true, prodAlert: false, buildFailure: false, subagents: 0) == .waiting(1), "waiting beats failed")
        expect(WingSlot.pick(waiting: 0, sessionFailures: 2, vpnDropped: true, justDone: true, prodAlert: true, buildFailure: true, subagents: 3) == .sessionFailed(2), "failed beats the rest")

        // Git status.
        let clean = GitStatusParse.parse("# branch.oid 1234567890abcdef\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n")
        expect(clean.isRepo && clean.branch == "main" && clean.changed == 0 && clean.ahead == 0 && clean.upstream == "origin/main", "git clean")
        expect(GitMarks.marks(clean).isEmpty && GitMarks.fullLine(clean) == "main · clean · tracks origin/main", "clean marks")
        let dirty = GitStatusParse.parse("# branch.oid abcdef1234567\n# branch.head feat/x\n# branch.upstream origin/feat/x\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b f1\n2 R. N... 100644 100644 100644 a b R100 n\to\nu UU N... 1 2 3 4 a b c d\n? new.txt\n")
        expect(dirty.changed == 4 && dirty.ahead == 2 && dirty.behind == 1, "git dirty counts")
        expect(GitMarks.marks(dirty) == ["●4", "↑2", "↓1"], "dirty marks")
        let none = GitStatusParse.parse("# branch.oid abcdef1234567\n# branch.head solo\n? a\n")
        expect(none.hasNoUpstream && GitMarks.marks(none) == ["●1", "no upstream"], "no upstream")
        let detached = GitStatusParse.parse("# branch.oid abcdef1234567\n# branch.head (detached)\n")
        expect(detached.isDetached && detached.branch == nil && !detached.hasNoUpstream && GitMarks.branchText(detached) == "HEAD abcdef1", "detached")
        let fresh = GitStatusParse.parse("# branch.oid (initial)\n# branch.head main\n")
        expect(fresh.head == nil && fresh.branch == "main", "initial commit")
        expect(GitMarks.branchText(SessionGit()) == nil && GitMarks.marks(SessionGit()).isEmpty, "not a repo shows nothing")

        // CI match.
        let ref = { (n: Int) in PipelineRef(workspace: "Fixture-WS", repo: "app", number: n) }
        func run(_ n: Int, _ state: BuildState, branch: String?, commit: String? = nil, created: Double, repo: PipelineRef? = nil) -> PipelineRun {
            PipelineRun(uuid: "u\(n)", ref: repo ?? ref(n), state: state, branch: branch, selectorKey: "branches:x", commit: commit, createdAt: created)
        }
        func build(_ id: String, _ state: BuildState, commit: String?, created: Double) -> EASBuild {
            EASBuild(id: id, state: state, platform: "ios", profile: "preview", commit: commit, createdAt: created, url: URL(string: "https://expo.dev/b/\(id)")!)
        }
        var git = SessionGit(repo: "fixture-ws/app", branch: "feat/x")
        git.isRepo = true; git.head = "abcdef1234567890"
        let runs = [run(1, .succeeded, branch: "feat/x", created: 10), run(2, .failed, branch: "feat/x", created: 20), run(3, .running, branch: "other", created: 30)]
        expect(SessionCI.match(git, runs: runs, builds: [])?.state == .failed, "latest run on the branch wins")
        expect(SessionCI.match(git, runs: runs, builds: [])?.name.hasPrefix("Pipeline #2") == true, "name carries the number")
        expect(SessionCI.match(git, runs: [run(3, .running, branch: "other", created: 30)], builds: []) == nil, "other branch is no match")
        expect(SessionCI.match(git, runs: [run(4, .running, branch: "feat/x", created: 5, repo: PipelineRef(workspace: "x", repo: "y", number: 4))], builds: []) == nil, "other repo is no match")
        expect(SessionCI.match(git, runs: [run(5, .succeeded, branch: "feat/x", created: 40), run(6, .canceled, branch: "feat/x", created: 50)], builds: [])?.state == .passed, "canceled skipped")
        expect(SessionCI.match(git, runs: [run(7, .paused, branch: "feat/x", created: 5)], builds: [])?.state == .running, "paused reads running")
        expect(SessionCI.match(git, runs: [run(8, .running, branch: "main", commit: "abcdef1", created: 5)], builds: [])?.state == .running, "short commit matches")
        expect(SessionCI.match(git, runs: [], builds: [build("e1", .running, commit: "abcdef1234567890", created: 5)])?.source == .eas, "EAS by commit")
        expect(SessionCI.match(git, runs: [], builds: [build("e2", .running, commit: "999999999", created: 5)]) == nil, "EAS other commit")
        expect(SessionCI.match(git, runs: [run(9, .succeeded, branch: "feat/x", created: 10)], builds: [build("e3", .failed, commit: "abcdef1", created: 20)])?.source == .eas, "newest across sources")
        expect(SessionCI.match(SessionGit(), runs: runs, builds: []) == nil, "not a repo")
        expect(!SessionCI.sameCommit("abc", "abc"), "too-short commit never matches")

        // Work folder: real repository with linked worktrees in a temp folder.
        do {
            let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("notch-wt-\(getpid())")
            try? FileManager.default.removeItem(atPath: root)
            func sh(_ dir: String, _ args: [String]) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", dir] + args
                p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
            try? FileManager.default.createDirectory(atPath: root + "/main/sub", withIntermediateDirectories: true)
            let main = root + "/main"
            sh(main, ["init", "-q", "-b", "main"]); sh(main, ["commit", "-q", "--allow-empty", "-m", "i"])
            sh(main, ["worktree", "add", "-q", "-b", "feat-a", root + "/wt-a"])
            sh(main, ["worktree", "add", "-q", "-b", "feat-b", root + "/wt-b"])
            try? FileManager.default.createDirectory(atPath: root + "/other", withIntermediateDirectories: true)
            sh(root + "/other", ["init", "-q"])
            let real = { (p: String) in WorkTree.real(p) }
            expect(WorkTree.info(of: main + "/sub/x.txt")?.root == real(main), "file in a subfolder: main checkout")
            expect(WorkTree.info(of: root + "/wt-a/new/dir/f.swift")?.isLinked == true, "file in a worktree: linked")
            expect(WorkTree.verdict(for: root + "/wt-a/f", start: main + "/sub") == .other(real(root + "/wt-a")), "worktree is another tree")
            expect(WorkTree.verdict(for: main + "/f", start: main + "/sub") == .start, "same checkout is the start")
            expect(WorkTree.verdict(for: root + "/other/f", start: main) == .ignored, "another repository is ignored")
            expect(WorkTree.verdict(for: "/etc/hosts", start: main) == .ignored, "outside any repository is ignored")
            expect(WorkTree.verdict(for: main + "/f", start: root + "/wt-a") == .other(real(main)), "started in a worktree, main is another tree")
            // Shell commands
            expect(WorkTree.folders(inCommand: "git -C \(root)/wt-b status", cwd: main) == [root + "/wt-b"], "git -C")
            expect(WorkTree.folders(inCommand: "cd ../wt-a && npm test", cwd: main) == [root + "/wt-a"], "cd relative")
            expect(WorkTree.folders(inCommand: "git worktree add -b x \(root)/wt-c origin/main", cwd: main) == [root + "/wt-c"], "worktree add skips -b value")
            expect(WorkTree.folders(inCommand: "git -C \"\(root)/wt a\" log", cwd: main) == [root + "/wt a"], "quoted path")
            expect(WorkTree.folders(inCommand: "cd $SOMEWHERE && ls", cwd: main).isEmpty, "unknown variable skipped")
            expect(WorkTree.folders(inCommand: "git -C \(root)/wt-a add . && cd \(root)/wt-b", cwd: main).last == root + "/wt-b", "last named wins")
            expect(WorkTree.folders(inCommand: "ls -C foo; echo cd x", cwd: main).isEmpty, "not a git -C or cd command")
            var a = SessionGit(branch: "feat-a"); a.isRepo = true
            var m = SessionGit(branch: "main"); m.isRepo = true
            expect(SessionWork(dir: root + "/wt-a", git: a, start: m).line == "checked out: main · working in: feat-a (wt-a)", "details line")
            try? FileManager.default.removeItem(atPath: root)
        }

        print("session-selfcheck: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
