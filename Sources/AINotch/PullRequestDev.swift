import Foundation

// Dev checks of the pull-request data layer, never the app:
//   --pr-selfcheck            the pure parts: parsing, needs, the review hash, event derivation
//                             and the seen-state round trip, the budget split. Exit 1 on a failure.
//   --pr-watch <seconds>      both Bitbucket lanes headless (Pipelines and pull requests, one
//                             client), printing each snapshot, each event and the request counts.
//                             `--prs-only` leaves Pipelines out. CLAUDE_NOTCH_TEST_OPENS="70,200"
//                             opens the notch at those seconds. Prints counts, states and keys;
//                             against the real API (no stub) never a title, branch or name.

enum PullRequestDev {
    /// Runs a dev flag and exits; returns when none was given.
    static func runIfAsked(_ arguments: [String]) {
        if arguments.contains("--pr-selfcheck") { exit(selfCheck()) }
        guard let index = arguments.firstIndex(of: "--pr-watch") else { return }
        let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 60 : 60
        let prsOnly = arguments.contains("--prs-only")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await watch(seconds: seconds, prsOnly: prsOnly)
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func line(_ started: Date, _ text: String) {
        FileHandle.standardError.write(Data("[\(Int(Date().timeIntervalSince(started)))s] \(text)\n".utf8))
    }

    static func watch(seconds: Double, prsOnly: Bool) async {
        let started = Date()
        let stubbed = BitbucketConfig.isStubbed
        let client = BitbucketClient.shared
        let prs = PullRequestSource(client: client, onChange: { snapshot in
            let mine = snapshot.prs.filter { $0.role == .mine }
            let review = snapshot.prs.filter { $0.role == .reviewing }
            let attention = ReviewStore.attention(snapshot.prs)
            var text = "prs status=\(snapshot.status?.text ?? "ok") mine=\(mine.count) review=\(review.count) attention=\(attention.count) quiet=\(snapshot.prs.count - attention.count) combined=\(snapshot.combinedQuery.map(String.init) ?? "-") me=\(snapshot.me?.how.components(separatedBy: " ").prefix(2).joined(separator: " ") ?? "-")"
            if stubbed {
                text += " | " + snapshot.prs.map { pr in
                    "\(pr.ref.key)[\(pr.role.rawValue) \(pr.approvals)/\(pr.approvalsNeeded) tasks \(pr.taskCount) comments \(pr.commentCount) new \(pr.newComments) build \(pr.build?.state.rawValue ?? "-") needs \(pr.needs.map(\.rawValue).joined(separator: "+"))]"
                }.joined(separator: " ")
            }
            line(started, text)
        }, onEvents: { events in
            for event in events {
                line(started, "event \(event.tag)" + (stubbed ? " \(event.pr.key) \(event.text)" : ""))
            }
        })
        var pipelines: BitbucketSource?
        if !prsOnly {
            let source = BitbucketSource(client: client) { snapshot in
                let running = snapshot.runs.filter { $0.state.isRunning }
                Task {
                    // Mine: the Pipelines owner's, or (against a stub, whose user is not the
                    // cached owner) the pull-request lane's account.
                    let me = await prs.debugMe()?.uuid
                    let mineRunning = running.contains { snapshot.owner?.owns($0) == true || (me != nil && $0.creatorUUID == me) }
                    line(started, "pipelines status=\(snapshot.status?.text ?? "ok") runs=\(snapshot.runs.count) running=\(running.count) mineRunning=\(mineRunning) requests: \(snapshot.requests.summary)")
                    await prs.setMyPipelineRunning(mineRunning)
                }
            }
            pipelines = source
            await source.start()
        }
        await prs.start()
        let opens = (ProcessInfo.processInfo.environment["CLAUDE_NOTCH_TEST_OPENS"] ?? "").split(separator: ",").compactMap { Double($0) }
        if !opens.isEmpty {
            Task.detached {
                for at in opens.sorted() {
                    let wait = at - Date().timeIntervalSince(started)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    line(started, "notch opened")
                    await prs.refreshSoon()
                    if let pipelines {
                        await pipelines.setPanelOpen(true)
                        try? await Task.sleep(for: .seconds(3))
                        await pipelines.setPanelOpen(false)
                    }
                }
            }
        }
        // The counts every minute.
        var elapsed = 0.0
        while elapsed < seconds {
            let step = min(60, seconds - elapsed)
            try? await Task.sleep(for: .seconds(step))
            elapsed += step
            let (pr, prNotModified) = await client.counts(.pullRequests)
            let (pl, plNotModified) = await client.counts(.pipelines)
            line(started, "counts pr: \(ReviewStore.summary(pr, notModified: prNotModified)) | pipelines: \(pl.summary), 304s \(plNotModified)")
        }
        let (pr, _) = await client.counts(.pullRequests)
        let (pl, _) = await client.counts(.pipelines)
        print("after \(Int(seconds)) s: pull requests \(pr.total) (cap \(BitbucketLane.pullRequests.hourlyCap)), pipelines \(pl.total) (cap \(BitbucketLane.pipelines.hourlyCap))")
    }

    // MARK: Self-check

    static func selfCheck() -> Int32 {
        var failures = 0
        var checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL \(what)")
            }
        }
        let me = "{me}"
        func object(id: Int, author: String, reviewers: [String], states: [String: String] = [:], draft: Bool = false,
                    comments: Int = 0, updated: String = "2026-10-15T10:00:00.000000+00:00") -> [String: Any] {
            var participants: [[String: Any]] = reviewers.map { uuid in
                ["role": "REVIEWER", "approved": states[uuid] == "approved", "state": states[uuid] as Any, "user": ["uuid": uuid, "display_name": uuid.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))]]
            }
            for (uuid, state) in states where !reviewers.contains(uuid) {
                participants.append(["role": "PARTICIPANT", "approved": state == "approved", "state": state, "user": ["uuid": uuid, "display_name": "P"]])
            }
            return ["id": id, "title": "t", "draft": draft, "state": "OPEN", "author": ["uuid": author, "display_name": "Author"],
                    "source": ["branch": ["name": "feature"]],
                    "destination": ["branch": ["name": "main"], "repository": ["full_name": "ws/app"]],
                    "reviewers": reviewers.map { ["uuid": $0, "display_name": $0] }, "participants": participants,
                    "task_count": 2, "comment_count": comments, "updated_on": updated,
                    "links": ["html": ["href": "https://bitbucket.org/ws/app/pull-requests/\(id)"]]]
        }

        // Parsing: role, reviews, approvals x/y, draft, my review.
        let mine = PRParse.pullRequest(object(id: 1, author: me, reviewers: ["{a}", "{b}"], states: ["{a}": "approved", "{c}": "approved"]), me: me, repo: nil)
        expect(mine?.role == .mine && mine?.approvals == 2 && mine?.approvalsNeeded == 2 && mine?.reviewers.count == 2, "parse mine: approvals 2 of 2 (one by a non-reviewer)")
        expect(mine?.source == "feature" && mine?.destination == "main" && mine?.taskCount == 2 && mine?.ref.key == "ws/app#1", "parse mine: branches, tasks, key")
        let review = PRParse.pullRequest(object(id: 2, author: "{a}", reviewers: [me, "{b}"], states: ["{b}": "changes_requested"]), me: me, repo: nil)
        expect(review?.role == .reviewing && review?.myReview == PRReview.none && review?.requester?.name == "Author", "parse reviewing: requester is the author")
        expect(review?.changesRequestedBy == ["b"], "parse reviewing: changes requested by b")
        expect(PRParse.pullRequest(object(id: 3, author: "{a}", reviewers: ["{b}"]), me: me, repo: nil) == nil, "parse: neither mine nor reviewing is skipped")
        var merged = object(id: 4, author: me, reviewers: [])
        merged["state"] = "MERGED"
        expect(PRParse.pullRequest(merged, me: me, repo: nil) == nil, "parse: a merged one is skipped")

        // Needs.
        expect(review?.needs == [.reviewRequested], "needs: review requested")
        let draftReview = PRParse.pullRequest(object(id: 5, author: "{a}", reviewers: [me], draft: true), me: me, repo: nil)
        expect(draftReview?.needs == [], "needs: a draft waits")
        let approvedReview = PRParse.pullRequest(object(id: 6, author: "{a}", reviewers: [me], states: [me: "approved"]), me: me, repo: nil)
        expect(approvedReview?.needs == [], "needs: already approved by me")
        expect(mine?.needs == [.approved], "needs: mine approved")
        var failing = mine!
        failing.build = PRBuild(state: .failed, key: "k u", pipeline: nil, url: nil)
        failing.newComments = 2
        expect(failing.needs == [.buildFailed, .newComments, .approved], "needs: failed build, comments, approved")
        let changed = PRParse.pullRequest(object(id: 7, author: me, reviewers: ["{a}"], states: ["{a}": "changes_requested"]), me: me, repo: nil)!
        expect(changed.needs == [.changesRequested], "needs: changes requested, not approved")
        let quiet = PRParse.pullRequest(object(id: 8, author: me, reviewers: ["{a}"]), me: me, repo: nil)!
        expect(quiet.needs.isEmpty, "needs: quiet")
        let order = ReviewStore.attention([quiet, mine!, changed, review!])
        expect(order.map(\.ref.id) == [2, 7, 1], "attention: review request, changes, approved; quiet left out")

        // The review hash.
        expect(PREvents.hash(["a": "approved", "b": "changes_requested"]) == PREvents.hash(["b": "changes_requested", "a": "approved"]), "hash: order does not matter")
        expect(PREvents.hash(["a": "approved"]) != PREvents.hash(["a": "changes_requested"]), "hash: a changed review changes it")
        expect(PREvents.hash([:]).count == 16, "hash: 16 hex characters")

        // Events: a review request once, and never again after a restart.
        let t0 = 1_800_000_000.0
        var (events, entry) = PREvents.derive(review!, entry: nil, me: me, now: t0, silent: false)
        expect(events.map(\.tag) == ["review"] && events.first?.text == "Author asked for your review", "events: review requested on first sight")
        (events, entry) = PREvents.derive(review!, entry: entry, me: me, now: t0 + 120, silent: false)
        expect(events.isEmpty, "events: review requested only once")
        let restored = try! JSONDecoder().decode(PRSeenEntry.self, from: JSONEncoder().encode(entry))
        expect(restored == entry, "seen-state: an entry survives a round trip")
        (events, _) = PREvents.derive(review!, entry: restored, me: me, now: t0 + 240, silent: false)
        expect(events.isEmpty, "seen-state: a restart does not re-announce")
        (events, _) = PREvents.derive(review!, entry: nil, me: me, now: t0, silent: true)
        expect(events.isEmpty, "events: the first look without a seen-state file is silent")
        (events, _) = PREvents.derive(draftReview!, entry: nil, me: me, now: t0, silent: false)
        expect(events.isEmpty, "events: a draft's review request waits")

        // Events: approvals and changes on mine, each once.
        let open = PRParse.pullRequest(object(id: 9, author: me, reviewers: ["{a}", "{b}"]), me: me, repo: nil)!
        var (_, mineEntry) = PREvents.derive(open, entry: nil, me: me, now: t0, silent: false)
        let unchanged = PREvents.derive(open, entry: mineEntry, me: me, now: t0 + 60, silent: false)
        expect(unchanged.events.isEmpty && unchanged.entry == mineEntry, "events: an unchanged pull request leaves its entry alone")
        let approvedOnce = PRParse.pullRequest(object(id: 9, author: me, reviewers: ["{a}", "{b}"], states: ["{a}": "approved"]), me: me, repo: nil)!
        (events, mineEntry) = PREvents.derive(approvedOnce, entry: mineEntry, me: me, now: t0 + 120, silent: false)
        expect(events.map(\.text) == ["Approved by a"], "events: approved by a")
        (events, mineEntry) = PREvents.derive(approvedOnce, entry: mineEntry, me: me, now: t0 + 180, silent: false)
        expect(events.isEmpty, "events: an approval is announced once")
        let mixed = PRParse.pullRequest(object(id: 9, author: me, reviewers: ["{a}", "{b}"], states: ["{a}": "approved", "{b}": "changes_requested"]), me: me, repo: nil)!
        (events, mineEntry) = PREvents.derive(mixed, entry: mineEntry, me: me, now: t0 + 240, silent: false)
        expect(events.map(\.tag) == ["changes"] && events.first?.text == "Changes requested by b", "events: changes requested by b")

        // Events: comments by others, grouped, at most once per 10 minutes; mine ignored.
        var talk = open
        talk.recentComments = [PRComment(id: 1, author: PRPerson(uuid: "{a}", name: "a"), createdAt: t0 + 300),
                               PRComment(id: 2, author: PRPerson(uuid: "{a}", name: "a"), createdAt: t0 + 310),
                               PRComment(id: 3, author: PRPerson(uuid: me, name: "me"), createdAt: t0 + 320)]
        (events, mineEntry) = PREvents.derive(talk, entry: mineEntry, me: me, now: t0 + 330, silent: false)
        expect(events.map(\.text) == ["2 new comments from a"], "events: 2 comments from a, mine left out")
        expect(PREvents.newComments(talk, entry: mineEntry, me: me) == 2, "new since seen: 2")
        talk.recentComments.append(PRComment(id: 4, author: PRPerson(uuid: "{b}", name: "b"), createdAt: t0 + 400))
        (events, mineEntry) = PREvents.derive(talk, entry: mineEntry, me: me, now: t0 + 410, silent: false)
        expect(events.isEmpty, "events: a comment within 10 minutes waits")
        (events, mineEntry) = PREvents.derive(talk, entry: mineEntry, me: me, now: t0 + 330 + 600, silent: false)
        expect(events.map(\.text) == ["1 new comment from b"], "events: the waiting comment comes with the next one, 10 minutes on")
        mineEntry.seenAt = t0 + 1000
        expect(PREvents.newComments(talk, entry: mineEntry, me: me) == 0, "new since seen: 0 after looking")

        // Events: a build failure once per failure; the first build seen is not news.
        var built = open
        built.build = PRBuild(state: .failed, key: "k1 https://bitbucket.org/ws/app/pipelines/results/40", pipeline: PipelineRef(workspace: "ws", repo: "app", number: 40), url: nil)
        var (_, buildEntry) = PREvents.derive(open, entry: nil, me: me, now: t0, silent: false)
        (events, buildEntry) = PREvents.derive(built, entry: buildEntry, me: me, now: t0 + 60, silent: false)
        expect(events.isEmpty, "events: the first build state seen is not news")
        built.build = PRBuild(state: .running, key: "k1 r", pipeline: nil, url: nil)
        (events, buildEntry) = PREvents.derive(built, entry: buildEntry, me: me, now: t0 + 120, silent: false)
        built.build = PRBuild(state: .failed, key: "k1 https://bitbucket.org/ws/app/pipelines/results/41", pipeline: PipelineRef(workspace: "ws", repo: "app", number: 41), url: nil)
        (events, buildEntry) = PREvents.derive(built, entry: buildEntry, me: me, now: t0 + 180, silent: false)
        expect(events.map(\.tag) == ["build"], "events: a new failure is announced")
        let dropped = ReviewStore.dropAlreadyNotified(events) { $0.number == 41 }
        let kept = ReviewStore.dropAlreadyNotified(events) { $0.number == 40 }
        expect(dropped.isEmpty && kept.count == 1, "events: a failure Pipelines already notified is dropped")
        (events, _) = PREvents.derive(built, entry: buildEntry, me: me, now: t0 + 240, silent: false)
        expect(events.isEmpty, "events: the same failure once")

        // Statuses, links, comments, merge checks, scope errors.
        let statuses: [String: Any] = ["values": [["state": "SUCCESSFUL", "key": "a", "url": "https://ci.example.com/1"],
                                                  ["state": "FAILED", "key": "b", "url": "https://bitbucket.org/ws/app/pipelines/results/77"]]]
        expect(PRParse.build(statuses)?.state == .failed && PRParse.build(statuses)?.pipeline?.number == 77, "statuses: any failure fails, with its run")
        expect(PRParse.build(["values": [["state": "INPROGRESS", "key": "a"], ["state": "SUCCESSFUL", "key": "b"]]])?.state == .running, "statuses: in progress")
        expect(PRParse.build(["values": []]) == nil, "statuses: none")
        expect(PRParse.pipelineRef("https://bitbucket.org/ws/app/addon/pipelines/home#!/results/12")?.key == "ws/app#12", "link: old addon form")
        let comments = PRParse.comments(["values": [["id": 1, "user": ["uuid": "{a}", "display_name": "a"], "created_on": "2026-10-15T10:00:00.000000+00:00", "deleted": false],
                                                    ["id": 2, "user": ["uuid": "{a}"], "created_on": "2026-10-15T10:00:00.000000+00:00", "deleted": true]]])
        expect(comments.count == 1 && comments[0].author.uuid == "{a}", "comments: a deleted one is left out")
        let merge = PRParse.mergeability(["values": [["type": "git_mergeability_check", "status": "PASSED", "required": true, "blocking": false],
                                                     ["type": "standard_merge_check", "status": "FAILED", "required": true, "blocking": true, "check": ["kind": "minimum_approvals"]]]], now: t0)
        expect(!merge.canMerge && merge.blocking.map(\.name) == ["minimum_approvals"], "merge checks: what blocks")
        let scope = Data(#"{"type":"error","error":{"message":"Your credentials lack one or more required privilege scopes.","detail":{"required":["read:pullrequest:bitbucket"],"granted":["read:pipeline:bitbucket"]}}}"#.utf8)
        expect(PRParse.isScopeError(scope) && !PRParse.isScopeError(Data(#"{"error":{"message":"You may not have access"}}"#.utf8)), "403: a scope error, and a repository one")
        expect(PRParse.isSourceError(Data(#"{"error":{"message":"Either a cset or a repo and commit hash must be provided"}}"#.utf8)), "400: the deleted-fork error")
        expect(!PRParse.listFields(withSource: false).contains("source") && PRParse.listFields(withSource: true).contains("values.source.branch.name"), "fields: with and without source")

        // builds.json: JSON 0 and 1 are numbers, true/false are not; pullRequests on by default.
        let configJSON = #"{"bitbucket":{"workspace":"ws","repos":["app"],"pullRequests":false},"datadog":{"monitors":"m","health":[{"label":"a","query":"q","scale":1,"amber":0,"minutes":1},{"label":"b","query":"q","amber":true,"minutes":"2"}]}}"#
        let parsed = BuildsConfig.parse(Data(configJSON.utf8))
        let health = parsed?.datadog?.health ?? []
        expect(health.count == 2 && health[0].scale == 1 && health[0].amber == 0 && health[0].window == 60, "config: 1 and 0 parse as numbers")
        expect(health.count == 2 && health[1].amber == nil && health[1].window == 120, "config: true is not a number, \"2\" is")
        expect(BuildsConfig.number(1) == 1 && BuildsConfig.number(0) == 0 && BuildsConfig.number(true) == nil && BuildsConfig.number(false) == nil && BuildsConfig.number(2.5) == 2.5, "config: the number parser")
        expect(parsed?.bitbucket?.pullRequests == false && BuildsConfig.parse(Data(#"{"bitbucket":{"repos":["ws/app"]}}"#.utf8))?.bitbucket?.pullRequests == true, "config: pullRequests off when false, on by default")

        // Setup's switch writes builds.json: off adds "pullRequests": false, on takes it out; the
        // rest of the file (order, numbers, other parts) stays byte for byte.
        let original = "{\n  \"eas\": {\n    \"account\": \"acme\",\n    \"slug\": \"app\",\n    \"projectId\": \"x\"\n  },\n  \"bitbucket\": {\n    \"workspace\": \"acme\",\n    \"repos\": [\n      \"app\"\n    ]\n  },\n  \"machine\": {\n    \"warnBelowMB\": 4096.0\n  }\n}\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-selfcheck-builds-\(getpid()).json")
        try? Data(original.utf8).write(to: file)
        let offError = BuildsConfig.setPullRequests(false, in: file)
        let off = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        expect(offError == nil && BuildsConfig.parse(Data(off.utf8))?.bitbucket?.pullRequests == false && off.contains("\"pullRequests\": false") && off.contains("4096.0"), "switch: off writes pullRequests false, numbers kept")
        let onError = BuildsConfig.setPullRequests(true, in: file)
        expect(onError == nil && (try? String(contentsOf: file, encoding: .utf8)) == original, "switch: on takes the key out, the file byte for byte as before")
        try? Data("{ not json".utf8).write(to: file)
        expect(BuildsConfig.setPullRequests(false, in: file) != nil && (try? String(contentsOf: file, encoding: .utf8)) == "{ not json", "switch: a broken file is left alone")
        try? FileManager.default.removeItem(at: file)

        // The collapsed wing: pull-request news after a pipeline failure, before subagents.
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: false, pullRequestNews: 2, subagents: 3, building: 1) == .pullRequestNews(2)
               && WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: true, pullRequestNews: 2, subagents: 0, building: 0) == .buildFailure,
               "wing: PR news before subagents, after a failure")
        // News parts: comments seen leave no news behind; a new approval is news again.
        var news = mine!
        news.newComments = 1
        news.recentComments = [PRComment(id: 1, author: PRPerson(uuid: "{a}", name: "a"), createdAt: t0)]
        let before = Set(ReviewStore.newsParts(news))
        news.newComments = 0
        expect(Set(ReviewStore.newsParts(news)).isSubset(of: before), "news: comments marked seen leave nothing unseen")
        let more = PRParse.pullRequest(object(id: 1, author: me, reviewers: ["{a}", "{b}"], states: ["{a}": "approved", "{b}": "approved", "{c}": "approved"]), me: me, repo: nil)!
        expect(!Set(ReviewStore.newsParts(more)).isSubset(of: before), "news: a second approval is news")

        // The budget split.
        expect(BitbucketLane.pipelines.hourlyTarget == 360 && BitbucketLane.pipelines.hourlyCap == 390, "budget: Pipelines 360, cap 390 (unchanged)")
        expect(BitbucketLane.pullRequests.hourlyTarget == 120 && BitbucketLane.pullRequests.hourlyCap == 150, "budget: pull requests 120, cap 150")
        expect(BitbucketLane.allCases.reduce(0) { $0 + $1.hourlyCap } <= 1000 * 6 / 10, "budget: both caps together within 60% of Bitbucket's 1,000 an hour")
        var worst = 0.0
        for repos in 1...40 {
            for workspaces in 1...4 {
                for running in [false, true] {
                    for locked in [false, true] {
                        let planned = PRBudget.plannedPerHour(repos: repos, mineWorkspaces: workspaces, pipelineRunning: running, locked: locked)
                        worst = max(worst, planned)
                        let interval = PRBudget.reviewInterval(repos: repos, mineWorkspaces: workspaces, pipelineRunning: running, locked: locked)
                        if interval < (running || locked ? 1200 : 600) { expect(false, "budget: review interval \(interval) below its base") }
                        if planned > BitbucketLane.pullRequests.hourlyTarget - PRBudget.detailsReserve + 0.001 {
                            expect(false, "budget: \(repos) repos, \(workspaces) workspaces planned \(planned)")
                        }
                    }
                }
            }
        }
        checks += 1
        expect(PRBudget.reviewInterval(repos: 7, mineWorkspaces: 1, pipelineRunning: false, locked: false) == 600, "budget: 7 repositories every 10 minutes")
        expect(PRBudget.reviewInterval(repos: 7, mineWorkspaces: 1, pipelineRunning: true, locked: false) == 1200, "budget: every 20 minutes while my pipeline runs")
        expect(PRBudget.plannedPerHour(repos: 7, mineWorkspaces: 1, pipelineRunning: false, locked: false) == 72, "budget: 7 repositories plan 72 an hour (mine 30, review 42)")
        print("pr-selfcheck: \(checks - failures)/\(checks) passed; the busiest schedule plans \(Int(worst.rounded())) an hour (target \(Int(BitbucketLane.pullRequests.hourlyTarget)), \(Int(PRBudget.detailsReserve)) kept for details)")
        return failures == 0 ? 0 : 1
    }
}
