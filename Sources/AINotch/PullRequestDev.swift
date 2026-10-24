import Foundation
import NotchCore

// Dev checks of the pull-request data layer, never the app:
//   --pr-selfcheck            the pure parts: parsing, needs, the review hash, event derivation
//                             and the seen-state round trip, the budget split, a session's pull
//                             request (remote and branch, the line, the brief, delivery) and the
//                             merged, declined and ready-to-merge news. Exit 1 on a failure.
//   --pr-watch <seconds>      both Bitbucket lanes headless (Pipelines and pull requests, one
//                             client), printing each snapshot, each event and the request counts.
//                             `--prs-only` leaves Pipelines out. CLAUDE_NOTCH_TEST_OPENS="70,200"
//                             opens the notch at those seconds. Prints counts, states and keys;
//                             against the real API (no stub) never a title, branch or name.
//                             CLAUDE_NOTCH_TEST_FEEDBACK=1 (stub only) also builds, at the end, the
//                             "Send to agent" brief of each of mine with something to fix.

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
        nonisolated(unsafe) var latest: [PullRequest] = []
        let prs = PullRequestSource(client: client, onChange: { snapshot in
            latest = snapshot.prs
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
        if stubbed, ProcessInfo.processInfo.environment["CLAUDE_NOTCH_TEST_FEEDBACK"] != nil {
            for pr in latest where pr.role == .mine && !pr.feedbackKinds.isEmpty {
                let kinds = pr.feedbackKinds
                let wantBuild = kinds.contains(.buildFailed)
                let comments = kinds.compactMap { kind -> Int? in if case .newComments(let n) = kind { return n } else { return nil } }.first ?? 0
                let data = await prs.feedback(for: pr.id, wantBuild: wantBuild, comments: comments, runUUID: nil)
                print("--- brief for \(pr.ref.key) (\(PRLine.text(pr)))\n\(PRBrief.compose(pr, feedback: data))")
            }
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
                    "source": ["branch": ["name": "feature"], "commit": ["hash": "abc123"]],
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
        expect(!PRParse.listFields(withSource: false).contains("source") && PRParse.listFields(withSource: true).contains("values.source.branch.name") && PRParse.listFields(withSource: true).contains("values.source.commit.hash"), "fields: with and without source")
        expect(mine?.head == "abc123", "parse: the head commit of the source")

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


        // A session's pull request: the remote and branch of its folder, matched to one of mine.
        expect(GitRemote.repo("git@bitbucket.org:ws/app.git") == "ws/app" && GitRemote.repo("ssh://git@bitbucket.org/ws/app.git") == "ws/app"
               && GitRemote.repo("https://user@bitbucket.org/ws/app.git") == "ws/app" && GitRemote.repo("https://bitbucket.org/ws/app/") == "ws/app"
               && GitRemote.repo("git@bitbucket.org-work:ws/app") == "ws/app", "remote: the Bitbucket forms")
        expect(GitRemote.repo("git@github.com:ws/app.git") == nil && GitRemote.repo("https://bitbucket.example.com/scm/x/y.git") == nil && GitRemote.repo("/Users/me/app") == nil, "remote: other hosts and paths are not Bitbucket Cloud")
        expect(GitRemote.repo(fromConfig: "remote.upstream.url git@github.com:x/y.git\nremote.fork.url git@bitbucket.org:me/app.git\nremote.origin.url git@bitbucket.org:ws/app.git") == "ws/app"
               && GitRemote.repo(fromConfig: "remote.upstream.url git@github.com:x/y.git\nremote.fork.url git@bitbucket.org:me/app.git") == "me/app", "remote: origin first, else the first on Bitbucket")
        let linkBase = PRParse.pullRequest(object(id: 21, author: me, reviewers: ["{a}"]), me: me, repo: nil)!
        var linkOther = linkBase
        linkOther.ref = PullRequestRef(workspace: "ws", repo: "app", id: 22)
        linkOther.source = "other"
        var linkNewer = linkBase
        linkNewer.ref = PullRequestRef(workspace: "ws", repo: "app", id: 23)
        linkNewer.updatedAt = linkBase.updatedAt + 10
        var linkReviewing = linkBase
        linkReviewing.role = .reviewing
        expect(PRLink.match(SessionGit(repo: "WS/App", branch: "feature"), in: [linkBase, linkOther])?.ref.id == 21, "link: same repository and source branch, repository case ignored")
        expect(PRLink.match(SessionGit(repo: "ws/app", branch: "other"), in: [linkBase, linkOther])?.ref.id == 22, "link: another branch, another pull request")
        expect(PRLink.match(SessionGit(repo: "ws/app", branch: "feature"), in: [linkBase, linkNewer])?.ref.id == 23, "link: the newest when two share a branch")
        expect(PRLink.match(SessionGit(repo: "ws/app", branch: "main"), in: [linkBase]) == nil && PRLink.match(SessionGit(repo: "ws/lib", branch: "feature"), in: [linkBase]) == nil
               && PRLink.match(SessionGit(repo: "ws/app", branch: nil), in: [linkBase]) == nil && PRLink.match(SessionGit(repo: nil, branch: "feature"), in: [linkBase]) == nil
               && PRLink.match(SessionGit(repo: "ws/app", branch: "feature"), in: [linkReviewing]) == nil, "link: no match for another branch or repository, a detached head, or one I only review")
        // The real thing: git in a temporary folder, asked as the app asks it.
        let gitFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-selfcheck-git-\(getpid())")
        try? FileManager.default.createDirectory(at: gitFolder, withIntermediateDirectories: true)
        func git(_ arguments: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", gitFolder.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        git(["init", "-q"]); git(["checkout", "-q", "-b", "feature"]); git(["remote", "add", "origin", "git@bitbucket.org:ws/app.git"])
        let resolved = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found: [String: SessionGit] = [:]
        let folderPath = gitFolder.path
        Task.detached {
            found = await SessionGitSource().resolve([folderPath, "/nonexistent-ai-notch-folder"])
            resolved.signal()
        }
        resolved.wait()
        expect(found[folderPath] == SessionGit(repo: "ws/app", branch: "feature") && found["/nonexistent-ai-notch-folder"] == SessionGit(repo: nil, branch: nil), "git: the branch and repository of a real folder, nothing for a missing one")
        try? FileManager.default.removeItem(at: gitFolder)

        // The pull request's line, per state.
        func prLine(_ change: (inout PullRequest) -> Void) -> String {
            var pr = linkBase
            change(&pr)
            return PRLine.text(pr)
        }
        let conflictChecks = PRMergeability(checks: [.init(name: "git_mergeability_check", status: "FAILED", required: true, blocking: true, type: "git_mergeability_check", reason: "conflicts")], fetchedAt: t0)
        let impossibleChecks = PRMergeability(checks: [.init(name: "git_mergeability_check", status: "FAILED", required: true, blocking: true, type: "git_mergeability_check", reason: "merge_impossible")], fetchedAt: t0)
        let undecidedChecks = PRMergeability(checks: [.init(name: "git_mergeability_check", status: "PENDING", required: true, blocking: false, type: "git_mergeability_check", reason: "")], fetchedAt: t0)
        let unknownChecks = PRMergeability(checks: [.init(name: "git_mergeability_check", status: "UNKNOWN", required: true, blocking: false, type: "git_mergeability_check")], fetchedAt: t0)
        let approvalChecks = PRMergeability(checks: [.init(name: "minimum_approvals", status: "FAILED", required: true, blocking: true, type: "standard_merge_check")], fetchedAt: t0)
        let passingChecks = PRMergeability(checks: [.init(name: "git_mergeability_check", status: "PASSED", required: true, blocking: false, type: "git_mergeability_check"),
                                                    .init(name: "minimum_approvals", status: "PASSED", required: true, blocking: false, type: "standard_merge_check")], fetchedAt: t0)
        let failedBuild = PRBuild(state: .failed, key: "k u", pipeline: PipelineRef(workspace: "ws", repo: "app", number: 45), url: URL(string: "https://bitbucket.org/ws/app/pipelines/results/45"), name: "Pipeline #45")
        expect(conflictChecks.hasConflict && !approvalChecks.hasConflict && !passingChecks.hasConflict && passingChecks.canMerge && !approvalChecks.canMerge, "merge checks: a conflict is told from a missing approval")
        expect(!impossibleChecks.hasConflict && impossibleChecks.cannotMerge && !conflictChecks.cannotMerge && !impossibleChecks.canMerge, "merge checks: merge_impossible is not a conflict, it is \"can't merge\"")
        let parsedGit = PRParse.mergeability(["values": [["type": "git_mergeability_check", "status": "FAILED", "required": true, "blocking": true, "reason": "conflicts"]]], now: t0)
        let parsedImpossible = PRParse.mergeability(["values": [["type": "git_mergeability_check", "status": "FAILED", "required": true, "blocking": true, "reason": "merge_impossible"]]], now: t0)
        let parsedPlain = PRParse.mergeability(["values": [["type": "git_mergeability_check", "status": "FAILED", "required": true, "blocking": true]]], now: t0)
        expect(parsedGit.hasConflict && !parsedImpossible.hasConflict && parsedImpossible.cannotMerge && !parsedPlain.hasConflict && parsedPlain.cannotMerge, "merge checks: the git check's reason is parsed; no reason is not a conflict")
        expect(!undecidedChecks.canMerge && !unknownChecks.canMerge && !undecidedChecks.hasConflict && !undecidedChecks.cannotMerge, "merge checks: a pending or unknown git check is not mergeable, and not a conflict")
        expect(!PRMergeability(checks: [.init(name: "failed_builds", status: "PASSED", required: true, blocking: false, type: "standard_merge_check")], fetchedAt: t0).hasApprovalCheck && approvalChecks.hasApprovalCheck, "merge checks: whether an approval rule exists")
        expect(prLine { _ in } == "PR #21 · open", "line: open")
        expect(prLine { $0.build = failedBuild } == "PR #21 · build failed", "line: build failed")
        expect(prLine { $0.merge = conflictChecks } == "PR #21 · merge conflict", "line: merge conflict")
        expect(prLine { $0.merge = impossibleChecks } == "PR #21 · can't merge" && prLine { $0.merge = impossibleChecks; $0.newComments = 1 } == "PR #21 · 1 new comment · can't merge", "line: can't merge for merge_impossible")
        var impossiblePR = linkBase
        impossiblePR.merge = impossibleChecks
        expect(impossiblePR.feedbackKinds.isEmpty && PRLine.tone(impossiblePR) == .attention, "feedback: can't merge is shown, not offered to an agent")
        expect(prLine { $0.newComments = 2 } == "PR #21 · 2 new comments" && prLine { $0.newComments = 1 } == "PR #21 · 1 new comment", "line: new comments")
        expect(prLine { $0.build = failedBuild; $0.merge = conflictChecks; $0.newComments = 2 } == "PR #21 · build failed · merge conflict · 2 new comments", "line: every kind of feedback, in the brief's order")
        let approvedPR = PRParse.pullRequest(object(id: 21, author: me, reviewers: ["{a}"], states: ["{a}": "approved"]), me: me, repo: nil)!
        var approvedReady = approvedPR
        approvedReady.merge = passingChecks
        var approvedBlocked = approvedPR
        approvedBlocked.merge = approvalChecks
        expect(PRLine.text(approvedReady) == "PR #21 · approved, can merge" && PRLine.text(approvedPR) == "PR #21 · approved" && PRLine.text(approvedBlocked) == "PR #21 · approved", "line: approved, and can merge once the checks pass")
        var undecidedPR = approvedPR
        undecidedPR.merge = PRMergeability(checks: passingChecks.checks.map { var c = $0; if c.isGit { c.status = "PENDING" }; return c }, fetchedAt: t0)
        expect(undecidedPR.isReadyToMerge == false && PRLine.text(undecidedPR) == "PR #21 · approved", "ready: a git check still pending is not ready")
        approvedReady.build = PRBuild(state: .running, key: "r", pipeline: nil, url: nil)
        expect(PRLine.text(approvedReady) == "PR #21 · approved" && approvedReady.isReadyToMerge == false, "line: a running build is not ready")
        expect(prLine { $0.isDraft = true } == "PR #21 · draft" && prLine { $0.build = PRBuild(state: .running, key: "r", pipeline: nil, url: nil) } == "PR #21 · build running", "line: draft, build running")
        let changesPR = PRParse.pullRequest(object(id: 21, author: me, reviewers: ["{a}"], states: ["{a}": "changes_requested"]), me: me, repo: nil)!
        expect(PRLine.text(changesPR) == "PR #21 · changes requested", "line: changes requested")
        expect(PRLine.tone(linkBase) == .quiet && PRLine.tone({ var pr = linkBase; pr.build = failedBuild; return pr }()) == .bad && PRLine.tone({ var pr = linkBase; pr.newComments = 1; return pr }()) == .attention && PRLine.tone(approvedReady) == .good, "line: tones")
        var reviewing = linkBase
        reviewing.role = .reviewing
        reviewing.build = failedBuild
        expect(reviewing.feedbackKinds.isEmpty && linkBase.feedbackKinds.isEmpty, "feedback: none on a quiet one, none on one I only review")

        // The brief, per kind. The log is cut to the last 40 lines; comments say where they are.
        let hundred = Data((0..<100).map { "log line \($0)" }.joined(separator: "\n").appending("\n").utf8)
        let tail = PRParse.logTail(hundred, ranged: false, lines: PRBrief.logLines)
        expect(tail.count == 40 && tail.first == "log line 60" && tail.last == "log line 99", "log: the last 40 lines")
        expect(PRParse.logTail(Data("cut off mid\nfull 1\nfull 2\n".utf8), ranged: true, lines: 40) == ["full 1", "full 2"], "log: a ranged answer drops its partial first line")
        expect(PRParse.isPartial(status: 200, contentRange: nil) == false && PRParse.isPartial(status: 206, contentRange: "bytes 0-1234/1235") == false
               && PRParse.isPartial(status: 206, contentRange: "bytes 1000-1234/1235") == true && PRParse.isPartial(status: 206, contentRange: nil) == true
               && PRParse.isPartial(status: 206, contentRange: "garbage") == true, "log: only an answer that does not start at byte 0 is partial")
        let shortLog = Data("first\nsecond\n".utf8)
        expect(PRParse.logTail(shortLog, ranged: PRParse.isPartial(status: 206, contentRange: "bytes 0-12/13"), lines: 40) == ["first", "second"], "log: a suffix range larger than the log keeps its first line")
        expect(PRParse.runUUID(["values": [["uuid": "{a}", "build_number": 44], ["uuid": "{b}", "build_number": 45]]], number: 45) == "{b}" && PRParse.runUUID(["values": []], number: 45) == nil, "pipeline: a run's uuid from its build number")
        expect(PRParse.logTail(Data("\u{1B}[31mred\u{1B}[0m\n\n".utf8), ranged: false, lines: 40) == ["red"], "log: colour codes and trailing blanks go")
        var briefBuild = linkBase
        briefBuild.build = failedBuild
        let withLog = PRBrief.compose(briefBuild, feedback: PRFeedbackData(step: "Test", log: tail, comments: []))
        expect(withLog.contains("Pull request #21") && withLog.contains("ws/app") && withLog.contains("Build failed: Pipeline #45, step \"Test\".")
               && withLog.contains("Last 40 lines of the step's log:") && withLog.contains("log line 99") && !withLog.contains("log line 59"), "brief: failed build with step and the log's tail")
        let secret = PRBrief.compose(briefBuild, feedback: PRFeedbackData(step: "Test", log: ["token=ATATT3xFfGF0abcdefghijklmnopqrstuv"], comments: []))
        expect(!secret.contains("ATATT3xFfGF0") && secret.contains("***"), "brief: secrets in the log are masked")
        expect(PRBrief.compose(briefBuild, feedback: PRFeedbackData()).contains("The log could not be read. See https://bitbucket.org/ws/app/pipelines/results/45."), "brief: a log that could not be read says so, with the link")
        var briefComments = linkBase
        briefComments.newComments = 2
        let commentText = PRBrief.compose(briefComments, feedback: PRFeedbackData(step: nil, log: nil, comments: [
            PRCommentText(author: "Alice", path: "src/a.swift", line: 42, text: "Use a guard\nhere."), PRCommentText(author: "Bob", path: nil, line: nil, text: "Looks off")]))
        expect(commentText.contains("New comments to address:") && commentText.contains("- Alice on src/a.swift:42: Use a guard here.") && commentText.contains("- Bob: Looks off") && !commentText.contains("Build failed"), "brief: new comments with author, file:line and text")
        expect(PRBrief.compose(briefComments, feedback: PRFeedbackData()).contains("2 new comments, whose text could not be read"), "brief: comments that could not be read")
        var briefConflict = linkBase
        briefConflict.merge = conflictChecks
        let conflictText = PRBrief.compose(briefConflict, feedback: PRFeedbackData())
        expect(conflictText.contains("Merge conflict: branch feature conflicts with main.") && conflictText.contains("Rebase it onto main (or merge main into it) and resolve the conflicts."), "brief: merge conflict names both branches")
        var briefAll = linkBase
        briefAll.build = failedBuild; briefAll.merge = conflictChecks; briefAll.newComments = 1
        let all = PRBrief.compose(briefAll, feedback: PRFeedbackData(step: "Test", log: ["x"], comments: [PRCommentText(author: "Alice", path: nil, line: nil, text: "hi")]))
        expect(all.range(of: "Build failed")!.lowerBound < all.range(of: "Merge conflict")!.lowerBound && all.range(of: "Merge conflict")!.lowerBound < all.range(of: "New comment")!.lowerBound, "brief: build, conflict, comments, in that order")
        let commentPage: [String: Any] = ["values": [
            ["id": 1, "user": ["uuid": "{a}", "display_name": "Alice"], "created_on": "2026-10-15T10:00:00.000000+00:00", "deleted": false, "content": ["raw": "first"], "inline": ["path": "a.swift", "to": 7]],
            ["id": 2, "user": ["uuid": me, "display_name": "Me"], "created_on": "2026-10-15T10:01:00.000000+00:00", "deleted": false, "content": ["raw": "mine"]],
            ["id": 3, "user": ["uuid": "{b}", "display_name": "Bob"], "created_on": "2026-10-15T10:02:00.000000+00:00", "deleted": false, "content": ["raw": "second"]],
            ["id": 4, "user": ["uuid": "{b}", "display_name": "Bob"], "created_on": "2026-10-15T10:03:00.000000+00:00", "deleted": true, "content": ["raw": "gone"]],
            ["id": 5, "user": ["uuid": "{b}", "display_name": "Bob"], "created_on": "2026-10-15T10:04:00.000000+00:00", "deleted": false, "content": ["raw": "  "]]]]
        let texts = PRParse.commentTexts(commentPage, me: me, limit: 8)
        expect(texts.map(\.text) == ["first", "second"] && texts[0].path == "a.swift" && texts[0].line == 7 && texts[1].path == nil, "comments: others' text, oldest first; mine, deleted and empty left out")
        expect(PRParse.commentTexts(commentPage, me: me, limit: 1).map(\.text) == ["second"], "comments: the newest ones when there are more than asked")

        // Delivery: a note for Claude Code mid-turn, the clipboard for everything else.
        expect(PRDelivery.route(isClaudeCode: true, phase: .working) == .note && PRDelivery.route(isClaudeCode: true, phase: .waiting) == .note
               && PRDelivery.route(isClaudeCode: true, phase: .idle) == .clipboard && PRDelivery.route(isClaudeCode: false, phase: .working) == .clipboard, "delivery: note only for Claude Code with a turn running")

        // Merged, declined: mine leaving the list is fetched by id once.
        let (_, closedSeen) = PREvents.derive(linkBase, entry: nil, me: me, now: t0, silent: false)
        let merged1 = PREvents.closed(linkBase, entry: closedSeen, fetched: ["state": "MERGED", "closed_by": ["uuid": "{a}", "display_name": "Alice"]], now: t0 + 60)
        expect(merged1.event?.tag == "merged" && merged1.event?.text == "Merged by Alice" && merged1.event?.title == linkBase.title && merged1.entry?.closeChecked == true, "closed: merged, with who merged it")
        expect(PREvents.closed(linkBase, entry: merged1.entry, fetched: ["state": "MERGED"], now: t0 + 120).event == nil, "closed: announced once")
        let declined1 = PREvents.closed(linkBase, entry: closedSeen, fetched: ["state": "DECLINED", "closed_by": ["display_name": "Bob"]], now: t0 + 60)
        expect(declined1.event?.tag == "declined" && declined1.event?.text == "Declined by Bob", "closed: declined")
        expect(PREvents.closed(linkBase, entry: closedSeen, fetched: ["state": "MERGED"], now: t0).event?.text == "Merged", "closed: merged by someone unnamed")
        let failedFetch = PREvents.closed(linkBase, entry: closedSeen, fetched: nil, now: t0 + 60)
        expect(failedFetch.event == nil && failedFetch.entry?.closeChecked == true, "closed: a failed fetch announces nothing and is not retried")
        let stillOpen = PREvents.closed(linkBase, entry: closedSeen, fetched: ["state": "OPEN"], now: t0 + 60)
        expect(stillOpen.event == nil && stillOpen.entry == closedSeen, "closed: still open means the list missed it; it is checked again when it really closes")
        expect(PREvents.closed(linkBase, entry: closedSeen, fetched: ["state": "SUPERSEDED"], now: t0).event == nil, "closed: superseded is not news")
        expect(PREvents.closed(reviewing, entry: nil, fetched: ["state": "MERGED"], now: t0).event == nil, "closed: one I only review is not announced")
        expect(PRParse.closure(["state": "MERGED", "closed_by": ["display_name": "Alice"]])?.by == "Alice" && PRParse.closure(["state": "OPEN"]) == nil, "closed: the answer's state and closer")
        let oldEntry = #"{"role":"mine","updatedOn":"x","participantsHash":"h","participants":{},"commentsNotifiedAt":1,"seenAt":1,"buildSeen":true,"reviewRequestNotified":false,"aliveAt":1}"#
        let decoded = try? JSONDecoder().decode(PRSeenEntry.self, from: Data(oldEntry.utf8))
        expect(decoded != nil && decoded?.mergeReady == nil && decoded?.closeChecked == nil, "seen-state: a file from before these notifications still loads")

        // Ready to merge: from blocked to every check passing, once per head commit.
        var blocked = linkBase
        blocked.merge = approvalChecks
        blocked.head = "h1"
        var ready = blocked
        ready.merge = passingChecks
        var (readyEvents, readyEntry) = PREvents.derive(blocked, entry: nil, me: me, now: t0, silent: false)
        expect(readyEvents.isEmpty && readyEntry.mergeReady == false, "ready: first sight, blocked: recorded")
        (readyEvents, readyEntry) = PREvents.derive(ready, entry: readyEntry, me: me, now: t0 + 60, silent: false)
        expect(readyEvents.map(\.tag) == ["ready"] && readyEvents.first?.text == "Approved and all merge checks pass" && readyEntry.readyHead == "h1", "ready: blocked then passing is announced, naming the approval rule that exists")
        var noRuleBefore = blocked
        noRuleBefore.merge = PRMergeability(checks: [.init(name: "failed_builds", status: "FAILED", required: true, blocking: true, type: "standard_merge_check")], fetchedAt: t0)
        var noRuleAfter = noRuleBefore
        noRuleAfter.merge = PRMergeability(checks: [.init(name: "failed_builds", status: "PASSED", required: true, blocking: false, type: "standard_merge_check")], fetchedAt: t0)
        let noRule = PREvents.derive(noRuleAfter, entry: PREvents.derive(noRuleBefore, entry: nil, me: me, now: t0, silent: false).entry, me: me, now: t0 + 60, silent: false)
        expect(noRule.events.first?.text == "All merge checks pass", "ready: no approval is claimed when there is no approval rule")
        (readyEvents, readyEntry) = PREvents.derive(ready, entry: readyEntry, me: me, now: t0 + 120, silent: false)
        expect(readyEvents.isEmpty, "ready: not twice")
        (readyEvents, readyEntry) = PREvents.derive(blocked, entry: readyEntry, me: me, now: t0 + 180, silent: false)
        (readyEvents, readyEntry) = PREvents.derive(ready, entry: readyEntry, me: me, now: t0 + 240, silent: false)
        expect(readyEvents.isEmpty, "ready: blocked and passing again on the same commit is not announced again")
        var pushed = blocked
        pushed.head = "h2"
        var pushedReady = pushed
        pushedReady.merge = passingChecks
        (readyEvents, readyEntry) = PREvents.derive(pushed, entry: readyEntry, me: me, now: t0 + 300, silent: false)
        (readyEvents, readyEntry) = PREvents.derive(pushedReady, entry: readyEntry, me: me, now: t0 + 360, silent: false)
        expect(readyEvents.map(\.tag) == ["ready"] && readyEntry.readyHead == "h2", "ready: a new commit that becomes ready is announced")
        let firstReady = PREvents.derive(ready, entry: nil, me: me, now: t0, silent: false)
        expect(firstReady.events.isEmpty && firstReady.entry.mergeReady == true, "ready: already ready on first sight is not news")
        var unknownEntry = PREvents.derive(linkBase, entry: nil, me: me, now: t0, silent: false).entry
        expect(unknownEntry.mergeReady == nil, "ready: no merge checks read yet")
        (readyEvents, unknownEntry) = PREvents.derive(ready, entry: unknownEntry, me: me, now: t0 + 60, silent: false)
        expect(readyEvents.isEmpty && unknownEntry.mergeReady == true, "ready: the first reading of the checks only records")
        var runningReady = ready
        runningReady.build = PRBuild(state: .running, key: "r", pipeline: nil, url: nil)
        var draftReady = ready
        draftReady.isDraft = true
        let (_, blockedEntry) = PREvents.derive(blocked, entry: nil, me: me, now: t0, silent: false)
        expect(PREvents.derive(runningReady, entry: blockedEntry, me: me, now: t0 + 60, silent: false).events.isEmpty
               && PREvents.derive(draftReady, entry: blockedEntry, me: me, now: t0 + 60, silent: false).events.isEmpty
               && PREvents.derive(ready, entry: blockedEntry, me: me, now: t0 + 60, silent: true).events.isEmpty, "ready: not while the build runs, for a draft, or in a silent first look")
        expect(PREvents.derive(ready, entry: blockedEntry, me: me, now: t0 + 60, silent: false).events.count == 1, "ready: ... and announced once the build is done")
        var notifyPrefs = ReviewStore.NotifyPrefs()
        expect(notifyPrefs.allows(.merged(by: nil)) && notifyPrefs.allows(.declined(by: nil)) && notifyPrefs.allows(.readyToMerge(approved: true)), "prefs: merged, declined and ready are on by default")
        notifyPrefs.closed = false
        notifyPrefs.ready = false
        expect(!notifyPrefs.allows(.merged(by: "a")) && !notifyPrefs.allows(.declined(by: "a")) && !notifyPrefs.allows(.readyToMerge(approved: false)) && notifyPrefs.allows(.approved(by: ["a"])), "prefs: each toggle turns off its own kind")


        // The control file: readable by me only, old files still decode, and the app and the hook
        // change it under the session's lock.
        let controlFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-selfcheck-control-\(getpid())")
        try? FileManager.default.createDirectory(at: controlFolder, withIntermediateDirectories: true)
        setenv("CLAUDE_NOTCH_SESSIONS", controlFolder.path, 1)
        SessionControl.write(SessionControl(note: "a note", at: 1, feedback: "brief", feedbackPR: 7, feedbackAt: 1), for: "s1")
        let controlMode = (try? FileManager.default.attributesOfItem(atPath: NotchPaths.control("s1").path))?[.posixPermissions] as? Int
        expect(controlMode == 0o600, "control: the file is readable by me only")
        expect((try? FileManager.default.contentsOfDirectory(atPath: controlFolder.path))?.contains { $0.hasSuffix(".tmp") } == false, "control: no temporary file is left behind")
        expect(SessionControl.read("s1")?.feedback == "brief" && SessionControl.read("s1")?.feedbackPR == 7 && SessionControl.read("s1")?.note == "a note", "control: feedback and note round-trip")
        try? Data(#"{"stop":true,"note":"old","at":5}"#.utf8).write(to: NotchPaths.control("old"))
        chmod(NotchPaths.control("old").path, 0o600)
        expect(SessionControl.read("old")?.stop == true && SessionControl.read("old")?.note == "old" && SessionControl.read("old")?.feedback == nil, "control: a file from before feedback still decodes")
        SessionControl.update("s1") { $0.note = nil; $0.stop = nil }
        expect(SessionControl.read("s1")?.feedback == "brief" && SessionControl.read("s1")?.note == nil, "control: a turn's end clears the note and keeps the feedback")
        SessionControl.update("s1") { $0.feedback = nil; $0.feedbackPR = nil; $0.feedbackAt = nil }
        expect(!FileManager.default.fileExists(atPath: NotchPaths.control("s1").path), "control: the file goes when nothing is asked")
        let heldLock = Darwin.open(NotchPaths.lock("s2").path, O_CREAT | O_RDWR, 0o600)
        flock(heldLock, LOCK_EX)
        let blockedWrite = SessionControl.update("s2", wait: 0.05) { $0.feedback = "x" }
        flock(heldLock, LOCK_UN)
        close(heldLock)
        expect(!blockedWrite && SessionControl.read("s2") == nil, "control: a write waits for the session's lock and gives up without changing anything")
        expect(SessionControl.update("s2", wait: 0.05) { $0.feedback = "x" } && SessionControl.read("s2")?.feedback == "x", "control: a write under a free lock lands")

        // A control file is only believed when it is a plain file of mine that no one else can
        // read or write, and small.
        try? Data(#"{"note":"from someone","at":9}"#.utf8).write(to: NotchPaths.control("open"))
        chmod(NotchPaths.control("open").path, 0o666)
        expect(SessionControl.read("open") == nil, "control: a file others can write is ignored")
        chmod(NotchPaths.control("open").path, 0o640)
        expect(SessionControl.read("open") == nil, "control: a file others can read is ignored")
        chmod(NotchPaths.control("open").path, 0o600)
        expect(SessionControl.read("open")?.note == "from someone", "control: the same file at 0600 is read")
        try? FileManager.default.removeItem(at: NotchPaths.control("link"))
        try? FileManager.default.createSymbolicLink(at: NotchPaths.control("link"), withDestinationURL: NotchPaths.control("open"))
        expect(SessionControl.read("link") == nil, "control: a symlink is not followed")
        let hugeNote = String(repeating: "x", count: SessionControl.maxFileBytes + 10)
        try? Data(#"{"feedback":"\#(hugeNote)","at":9}"#.utf8).write(to: NotchPaths.control("huge"))
        chmod(NotchPaths.control("huge").path, 0o600)
        expect(SessionControl.read("huge") == nil, "control: a file over 64 KB is not read")
        let wroteOpen = SessionControl.update("open") { $0.feedback = "mine" }
        chmod(NotchPaths.control("open").path, 0o666)
        expect(SessionControl.read("open") == nil && wroteOpen, "control: update wrote a 0600 file, now widened and ignored")
        SessionControl.update("open") { $0.feedback = "fresh" }
        expect(SessionControl.read("open")?.feedback == "fresh" && SessionControl.read("open")?.note == nil, "control: update replaces an untrusted file with a fresh 0600 one, keeping none of it")
        let crlf = SessionControl.feedbackContext("one\r\ntwo\rthree\nfour", pullRequest: 4)
        let crlfLines = crlf.components(separatedBy: "\n").filter { $0.hasPrefix(">") }
        expect(crlfLines == ["> one", "> two", "> three", "> four"] && !crlf.contains("\r"), "brief: \\r\\n, \\r and \\n lines are each quoted")
        expect(SessionControl.cut(String(repeating: "a", count: 9000), SessionControl.feedbackLimit).hasSuffix("… (cut)") && SessionControl.cut("short", 10) == "short", "brief: text over the cap is cut and marked")
        expect(PRParse.logTail(Data("a\r\nb\r\nc\r\n".utf8), ranged: false, lines: 40) == ["a", "b", "c"], "log: \\r\\n line ends split into lines")
        expect(PRBudget.closedPerHour == 6, "budget: at most 6 reads an hour by id for mine that left the list")
        unsetenv("CLAUDE_NOTCH_SESSIONS")
        try? FileManager.default.removeItem(at: controlFolder)

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
        expect(Double(PRBudget.mergeMaxPRs) * 3600 / PRBudget.mergeEvery <= Double(PRBudget.mergePerHour), "budget: the merge-check schedule (4 pull requests every 15 minutes = 16) fits its 18 an hour")
        expect(PRBudget.plannedPerHour(repos: 7, mineWorkspaces: 1, pipelineRunning: false, locked: false) + PRBudget.detailsReserve + Double(PRBudget.mergePerHour) <= BitbucketLane.pullRequests.hourlyTarget, "budget: 7 repositories, details and merge checks together stay within 120 an hour")
        print("pr-selfcheck: \(checks - failures)/\(checks) passed; the busiest schedule plans \(Int(worst.rounded())) an hour (target \(Int(BitbucketLane.pullRequests.hourlyTarget)), \(Int(PRBudget.detailsReserve)) kept for details)")
        return failures == 0 ? 0 : 1
    }
}
