import CryptoKit
import Foundation

// Bitbucket pull requests: mine, and the ones waiting for my review. The model, how an answer is
// parsed, what "needs something" means, the events a later notification step posts, and the
// seen-state that keeps a restart from announcing anything twice. The polling is in
// PullRequestSource.swift, the main-thread store in ReviewStore.swift.

struct PullRequestRef: Hashable, Sendable, Codable {
    var workspace: String
    var repo: String
    var id: Int

    var key: String { "\(workspace)/\(repo)#\(id)" }
    var repoKey: String { "\(workspace)/\(repo)" }

    /// "ws/repo" (destination.repository.full_name) and an id.
    init?(fullName: String, id: Int) {
        let parts = fullName.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(workspace: parts[0], repo: parts[1], id: id)
    }

    init(workspace: String, repo: String, id: Int) {
        self.workspace = workspace
        self.repo = repo
        self.id = id
    }
}

struct PRPerson: Equatable, Sendable, Codable {
    var uuid: String?
    var name: String
}

/// A participant's review: Bitbucket's `state` (approved, changes_requested, or null).
enum PRReview: String, Sendable, Codable {
    case none
    case approved
    case changesRequested = "changes_requested"
}

struct PRParticipant: Equatable, Sendable {
    var person: PRPerson
    var review: PRReview
    /// Added as a reviewer (role REVIEWER), not only someone who commented or approved.
    var isReviewer: Bool
}

/// A comment's author and time; never its text (it is not even asked for).
struct PRComment: Equatable, Sendable {
    var id: Int
    var author: PRPerson
    var createdAt: Double
}

enum PRRole: String, Sendable, Codable {
    /// I wrote it.
    case mine
    /// I am one of its reviewers.
    case reviewing
}

/// The builds reported on the pull request's commit (`/statuses`), as one state.
struct PRBuild: Equatable, Sendable {
    var state: BuildState
    /// What identifies this outcome: the failing status's key and link, so the same failure is
    /// announced once and a new run's failure again.
    var key: String
    /// The Pipelines run behind it, when the status links to one.
    var pipeline: PipelineRef?
    var url: URL?
    /// The status's own name ("Pipeline #45"), when it has one.
    var name: String? = nil
}

/// Why a pull request shows as its own row; in this order of urgency.
enum PRNeed: String, Sendable, CaseIterable {
    case reviewRequested, changesRequested, buildFailed, newComments, approved

    var label: String {
        switch self {
        case .reviewRequested: return "Review requested"
        case .changesRequested: return "Changes requested"
        case .buildFailed: return "Build failed"
        case .newComments: return "New comments"
        case .approved: return "Approved"
        }
    }
}

struct PullRequest: Equatable, Sendable, Identifiable {
    var ref: PullRequestRef
    var title: String
    var isDraft: Bool
    var author: PRPerson
    var source: String?
    var destination: String?
    var role: PRRole
    /// Reviewers and anyone else who approved or asked for changes, by name.
    var participants: [PRParticipant]
    /// My own review, on one I review.
    var myReview: PRReview
    /// Open tasks (task_count).
    var taskCount: Int
    var commentCount: Int
    var updatedOn: String
    var updatedAt: Double
    var url: URL?
    /// From /statuses, once read.
    var build: PRBuild?
    /// The newest comments (at most 10), once read.
    var recentComments: [PRComment] = []
    /// Comments by others since I last looked (from the seen-state).
    var newComments = 0
    /// The source branch's head commit, when the list gave it: a push makes a new one.
    var head: String? = nil
    /// Merge checks, once read (only for my pull requests, on a slow schedule).
    var merge: PRMergeability?

    var id: String { ref.key }
    var reviewers: [PRParticipant] { participants.filter(\.isReviewer) }
    /// Approvals x of y: approvals from anyone, out of the reviewers (or the approvals, if more).
    var approvals: Int { participants.filter { $0.review == .approved }.count }
    var approvalsNeeded: Int { max(reviewers.count, approvals) }
    var changesRequestedBy: [String] { participants.filter { $0.review == .changesRequested }.map(\.person.name) }
    /// Who asked for my review. Bitbucket does not say who added a reviewer; the author does
    /// in practice, so it is the author.
    var requester: PRPerson? { role == .reviewing ? author : nil }

    /// What this pull request needs from me now; empty for a quiet one.
    var needs: [PRNeed] {
        var needs: [PRNeed] = []
        if role == .reviewing, myReview == .none, !isDraft { needs.append(.reviewRequested) }
        if role == .mine, !changesRequestedBy.isEmpty { needs.append(.changesRequested) }
        if role == .mine, build?.state == .failed { needs.append(.buildFailed) }
        if newComments > 0 { needs.append(.newComments) }
        if role == .mine, approvals > 0, changesRequestedBy.isEmpty { needs.append(.approved) }
        return needs
    }

    var needsSomething: Bool { !needs.isEmpty }

    /// Whether mine can be merged now: every merge check passes and the build is not failed or
    /// running. Nil while unknown (not mine, a draft, or the checks not read yet).
    var isReadyToMerge: Bool? {
        guard role == .mine, !isDraft, let merge, !merge.checks.isEmpty else { return nil }
        if let state = build?.state, state == .failed || state.isRunning { return false }
        return merge.canMerge
    }
}

/// Merge checks, read only when asked (`/mergeability/checks`).
struct PRMergeability: Equatable, Sendable {
    struct Check: Equatable, Sendable {
        /// The check's name (a custom check's), else its kind ("failed_builds"), else its type.
        var name: String
        /// PASSED, FAILED or PENDING.
        var status: String
        var required: Bool
        var blocking: Bool
        /// Bitbucket's type of the check ("git_mergeability_check" is the conflict check).
        var type = ""
        /// Why the git check says what it says: "conflicts", "merge_impossible", ...
        var reason = ""

        /// Bitbucket's own check of whether the branch merges with git.
        var isGit: Bool { type.lowercased().contains("git_mergeability") }
        private var fails: Bool { status == "FAILED" || blocking }

        /// The git check fails because the branches conflict (its reason says "conflicts").
        var isConflict: Bool { isGit && fails && reason.lowercased() == "conflicts" }

        /// The git check fails for another reason ("merge_impossible", or none given): the branch
        /// cannot be merged, but not because of a conflict an agent could resolve.
        var isUnmergeable: Bool { isGit && fails && !isConflict }

        /// The git check has not said yes: still working it out, or unknown.
        var isUndecided: Bool { isGit && !fails && status != "PASSED" }
    }

    var checks: [Check]
    var fetchedAt: Double

    /// The branch no longer merges cleanly.
    var hasConflict: Bool { checks.contains(where: \.isConflict) }
    /// The merge checks include an approval rule ("minimum_approvals" and the like).
    var hasApprovalCheck: Bool { checks.contains { ($0.name + " " + $0.type).lowercased().contains("approval") } }
    /// The branch cannot be merged, and not by conflict.
    var cannotMerge: Bool { checks.contains(where: \.isUnmergeable) }

    /// The checks that stop a merge now.
    var blocking: [Check] { checks.filter(\.blocking) }
    /// Nothing blocks, and git has said the branch merges (an unknown or pending git check does
    /// not count as mergeable).
    var canMerge: Bool { blocking.isEmpty && !checks.contains(where: \.isUndecided) }
}

/// Something worth telling me about one pull request. Derived on each poll and handed on; a
/// later step decides which become notifications (only while the screen is locked).
struct PREvent: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case approved(by: [String])
        case changesRequested(by: [String])
        case newComments(count: Int, from: [String])
        case reviewRequested(by: String)
        case buildFailed(pipeline: PipelineRef?)
        /// One of mine closed: merged (by whom, when Bitbucket says), declined, or every merge
        /// check now passes.
        case merged(by: String?)
        case declined(by: String?)
        /// `approved`: the merge checks include an approval rule.
        case readyToMerge(approved: Bool)
    }

    var kind: Kind
    var pr: PullRequestRef
    var title: String
    var url: URL?
    var at: Double

    var id: String { "\(pr.key) \(tag) \(Int(at))" }

    var tag: String {
        switch kind {
        case .approved: return "approved"
        case .changesRequested: return "changes"
        case .newComments: return "comments"
        case .reviewRequested: return "review"
        case .buildFailed: return "build"
        case .merged: return "merged"
        case .declined: return "declined"
        case .readyToMerge: return "ready"
        }
    }

    /// A short line: "Approved by Alice", "3 new comments from Bob".
    var text: String {
        func names(_ list: [String]) -> String {
            list.count <= 2 ? list.joined(separator: " and ") : "\(list[0]) and \(list.count - 1) others"
        }
        switch kind {
        case .approved(let by): return "Approved by \(names(by))"
        case .changesRequested(let by): return "Changes requested by \(names(by))"
        case .newComments(let count, let from): return "\(count) new comment\(count == 1 ? "" : "s") from \(names(from))"
        case .reviewRequested(let by): return "\(by) asked for your review"
        case .buildFailed: return "Build failed"
        case .merged(let by): return by.map { "Merged by \($0)" } ?? "Merged"
        case .declined(let by): return by.map { "Declined by \($0)" } ?? "Declined"
        case .readyToMerge(let approved): return approved ? "Approved and all merge checks pass" : "All merge checks pass"
        }
    }
}

// MARK: Parsing

enum PRParse {
    /// What a list asks for. `source.*` is left out of a repository whose list Bitbucket fails
    /// on (a 400 "Either a cset or a repo and commit hash must be provided" when one open pull
    /// request comes from a deleted fork).
    static func listFields(withSource: Bool) -> String {
        var fields = ["id", "title", "draft", "state", "author.uuid", "author.display_name",
                      "destination.branch.name", "destination.repository.full_name",
                      "participants.role", "participants.state", "participants.approved",
                      "participants.user.uuid", "participants.user.display_name",
                      "reviewers.uuid", "reviewers.display_name",
                      "task_count", "comment_count", "updated_on", "links.html.href"]
        if withSource { fields.insert(contentsOf: ["source.branch.name", "source.commit.hash"], at: 6) }
        return "size,next," + fields.map { "values." + $0 }.joined(separator: ",")
    }

    static let statusFields = "values.state,values.key,values.name,values.url,values.updated_on"
    static let commentFields = "values.id,values.user.uuid,values.user.display_name,values.created_on,values.deleted"

    private static func person(_ object: Any?) -> PRPerson? {
        guard let object = object as? [String: Any] else { return nil }
        let uuid = object["uuid"] as? String
        let name = (object["display_name"] as? String) ?? (object["nickname"] as? String) ?? "Someone"
        return PRPerson(uuid: uuid, name: name)
    }

    /// One pull request from a list page, as mine or one I review; nil when it is neither (or
    /// not open). `repo` is where it was listed; the workspace endpoint names it in
    /// destination.repository.full_name.
    static func pullRequest(_ object: [String: Any], me: String, repo: BitbucketRepo?) -> PullRequest? {
        guard let id = object["id"] as? Int else { return nil }
        if let state = object["state"] as? String, state.uppercased() != "OPEN" { return nil }
        let destination = object["destination"] as? [String: Any]
        let fullName = ((destination?["repository"] as? [String: Any])?["full_name"] as? String)
        guard let ref = fullName.flatMap({ PullRequestRef(fullName: $0, id: id) })
                ?? repo.map({ PullRequestRef(workspace: $0.workspace, repo: $0.repo, id: id) }) else { return nil }
        let author = person(object["author"]) ?? PRPerson(uuid: nil, name: "Someone")
        // Reviewers first, then what participants add: their review, and approvers who are not
        // reviewers.
        var byKey: [String: PRParticipant] = [:]
        var order: [String] = []
        for reviewer in object["reviewers"] as? [Any] ?? [] {
            guard let who = person(reviewer) else { continue }
            let key = who.uuid ?? who.name
            if byKey[key] == nil { order.append(key) }
            byKey[key] = PRParticipant(person: who, review: .none, isReviewer: true)
        }
        for item in object["participants"] as? [[String: Any]] ?? [] {
            guard let who = person(item["user"]) else { continue }
            let key = who.uuid ?? who.name
            var review = PRReview(rawValue: (item["state"] as? String ?? "").lowercased()) ?? .none
            if review == .none, item["approved"] as? Bool == true { review = .approved }
            let isReviewer = (item["role"] as? String)?.uppercased() == "REVIEWER" || byKey[key]?.isReviewer == true
            // A participant who only commented is not shown.
            guard isReviewer || review != .none else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key] = PRParticipant(person: who, review: review, isReviewer: isReviewer)
        }
        let participants = order.compactMap { byKey[$0] }
        let role: PRRole
        if author.uuid == me {
            role = .mine
        } else if participants.contains(where: { $0.isReviewer && $0.person.uuid == me }) {
            role = .reviewing
        } else {
            return nil
        }
        let updatedOn = object["updated_on"] as? String ?? ""
        let link = ((object["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String
        return PullRequest(
            ref: ref, title: object["title"] as? String ?? "Pull request #\(id)", isDraft: object["draft"] as? Bool ?? false,
            author: author,
            source: (((object["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String),
            destination: ((destination?["branch"] as? [String: Any])?["name"] as? String),
            role: role, participants: participants,
            myReview: participants.first { $0.person.uuid == me }?.review ?? .none,
            taskCount: object["task_count"] as? Int ?? 0, commentCount: object["comment_count"] as? Int ?? 0,
            updatedOn: updatedOn, updatedAt: buildTime(updatedOn) ?? 0,
            url: link.flatMap(URL.init(string:)) ?? URL(string: "https://bitbucket.org/\(ref.workspace)/\(ref.repo)/pull-requests/\(id)"),
            head: (((object["source"] as? [String: Any])?["commit"] as? [String: Any])?["hash"] as? String))
    }

    /// A pull request fetched by id after it left the open list: how it closed and who closed
    /// it. Nil when it is still open (or the answer is not a pull request).
    static func closure(_ object: [String: Any]) -> (merged: Bool, by: String?)? {
        guard let state = (object["state"] as? String)?.uppercased(), state == "MERGED" || state == "DECLINED" else { return nil }
        let by = (object["closed_by"] as? [String: Any]).flatMap { person($0)?.name }
        return (state == "MERGED", by)
    }

    /// The builds on the pull request's head as one state: any failed is failed, else any in
    /// progress is running, else all successful is succeeded; a stopped one is canceled.
    static func build(_ page: [String: Any]) -> PRBuild? {
        let values = page["values"] as? [[String: Any]] ?? []
        guard !values.isEmpty else { return nil }
        func pick(_ state: String) -> [String: Any]? { values.first { ($0["state"] as? String)?.uppercased() == state } }
        let chosen: (BuildState, [String: Any])
        if let failed = pick("FAILED") { chosen = (.failed, failed) }
        else if let running = pick("INPROGRESS") { chosen = (.running, running) }
        else if let stopped = pick("STOPPED") { chosen = (.canceled, stopped) }
        else { chosen = (.succeeded, values[0]) }
        let link = chosen.1["url"] as? String
        let key = "\(chosen.1["key"] as? String ?? "?") \(link ?? "")"
        return PRBuild(state: chosen.0, key: key, pipeline: link.flatMap(pipelineRef), url: link.flatMap(URL.init(string:)),
                       name: (chosen.1["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A Pipelines run from a status link: `…/pipelines/results/<n>` (what Bitbucket writes
    /// now) or the older `…/addon/pipelines/home#!/results/<n>`.
    static func pipelineRef(_ link: String) -> PipelineRef? {
        let pattern = #"bitbucket\.org/([^/]+)/([^/]+)/(?:addon/pipelines/home#!/results|pipelines/results)/([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
              let workspace = Range(match.range(at: 1), in: link), let repo = Range(match.range(at: 2), in: link),
              let number = Range(match.range(at: 3), in: link).flatMap({ Int(link[$0]) }) else { return nil }
        return PipelineRef(workspace: String(link[workspace]), repo: String(link[repo]), number: number)
    }

    static func comments(_ page: [String: Any]) -> [PRComment] {
        (page["values"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, item["deleted"] as? Bool != true,
                  let created = buildTime(item["created_on"]) else { return nil }
            return PRComment(id: id, author: person(item["user"]) ?? PRPerson(uuid: nil, name: "Someone"), createdAt: created)
        }
    }

    static func mergeability(_ page: [String: Any], now: Double) -> PRMergeability {
        let checks: [PRMergeability.Check] = (page["values"] as? [[String: Any]] ?? []).map { item in
            let check = item["check"] as? [String: Any]
            let name = (check?["name"] as? String) ?? (check?["kind"] as? String) ?? (item["type"] as? String) ?? "check"
            return PRMergeability.Check(name: name, status: (item["status"] as? String ?? "").uppercased(),
                                        required: item["required"] as? Bool ?? false, blocking: item["blocking"] as? Bool ?? false,
                                        type: item["type"] as? String ?? "",
                                        reason: (item["reason"] as? String) ?? (check?["reason"] as? String) ?? "")
        }
        return PRMergeability(checks: checks, fetchedAt: now)
    }

    /// A 403 that is about the token's scopes (Bitbucket says "…lack one or more required
    /// privilege scopes", with `detail.required`), not about one repository's permissions.
    static func isScopeError(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        let message = (error["message"] as? String ?? "").lowercased()
        return message.contains("scope") || (error["detail"] as? [String: Any])?["required"] != nil
    }

    /// The 400 Bitbucket answers for a list holding a pull request whose source is gone.
    static func isSourceError(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(2000), as: UTF8.self).lowercased()
        return text.contains("cset") || text.contains("commit hash")
    }
}

// MARK: Seen-state and events

/// What was last known of one pull request, kept in `~/.claude/notch/pr-seen.json` so a restart
/// announces nothing twice.
struct PRSeenEntry: Codable, Equatable, Sendable {
    var role: PRRole
    var updatedOn: String
    /// A hash of the participants' reviews (uuid=state, sorted): unchanged means no review news.
    var participantsHash: String
    /// The reviews themselves (uuid → approved / changes_requested), to say who changed.
    var participants: [String: String]
    /// The newest comment by someone else already announced (or the time it was first seen).
    var commentsNotifiedAt: Double
    /// When comments were last announced: at most once per 10 minutes per pull request.
    var commentEventAt: Double?
    /// When I last looked at it: comments by others after this are new.
    var seenAt: Double
    /// Whether its build was known once (the first one is not news), and the failure announced.
    var buildSeen: Bool
    var buildFailedKey: String?
    var reviewRequestNotified: Bool
    /// Whether every merge check passed when last read (nil: not read yet), and the head commit
    /// "ready to merge" was announced for: once per commit.
    var mergeReady: Bool?
    var readyHead: String?
    /// Left the open list and was fetched by id once, whatever came back.
    var closeChecked: Bool?
    /// Last time it was in a list: entries not seen for 3 days are dropped.
    var aliveAt: Double
}

enum PREvents {
    /// Comments on one pull request are announced at most this often.
    static let commentGap: Double = 600
    static let forgetAfter: Double = 3 * 86_400

    /// The reviews that count, by participant: approved or changes requested.
    static func reviews(_ pr: PullRequest) -> [String: String] {
        var states: [String: String] = [:]
        for participant in pr.participants where participant.review != .none {
            states[participant.person.uuid ?? participant.person.name] = participant.review.rawValue
        }
        return states
    }

    static func hash(_ reviews: [String: String]) -> String {
        let text = reviews.keys.sorted().map { "\($0)=\(reviews[$0]!)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Comments by others after a time.
    static func othersComments(_ pr: PullRequest, me: String, after: Double) -> [PRComment] {
        pr.recentComments.filter { $0.author.uuid != me && $0.createdAt > after }
    }

    /// The events one poll brings for a pull request, and its updated entry. `entry` nil: seen
    /// for the first time, which is news only for a review request. `silent`: the very first
    /// look with no seen-state file at all, which only records.
    static func derive(_ pr: PullRequest, entry: PRSeenEntry?, me: String, now: Double, silent: Bool) -> (events: [PREvent], entry: PRSeenEntry) {
        let states = reviews(pr)
        let digest = hash(states)
        var events: [PREvent] = []
        func emit(_ kind: PREvent.Kind) {
            if !silent { events.append(PREvent(kind: kind, pr: pr.ref, title: pr.title, url: pr.url, at: now)) }
        }
        let wantsReview = pr.role == .reviewing && pr.myReview == .none && !pr.isDraft
        guard var next = entry else {
            if wantsReview { emit(.reviewRequested(by: pr.author.name)) }
            let newest = othersComments(pr, me: me, after: 0).map(\.createdAt).max() ?? 0
            let entry = PRSeenEntry(
                role: pr.role, updatedOn: pr.updatedOn, participantsHash: digest, participants: states,
                commentsNotifiedAt: max(now, newest), commentEventAt: nil, seenAt: max(now, newest),
                buildSeen: pr.build != nil, buildFailedKey: pr.build?.state == .failed ? pr.build?.key : nil,
                // Already acted on, or announced now: not again. A draft waits until it is ready.
                reviewRequestNotified: pr.role == .reviewing && (wantsReview || pr.myReview != .none),
                mergeReady: pr.isReadyToMerge, readyHead: nil, closeChecked: nil, aliveAt: now)
            return (events, entry)
        }
        // Reviews on mine: who newly approved, who newly asked for changes.
        if pr.role == .mine, digest != next.participantsHash {
            let names = Dictionary(pr.participants.map { ($0.person.uuid ?? $0.person.name, $0.person.name) }, uniquingKeysWith: { a, _ in a })
            let approved = states.filter { $0.value == PRReview.approved.rawValue && next.participants[$0.key] != $0.value }.keys.sorted()
            let changes = states.filter { $0.value == PRReview.changesRequested.rawValue && next.participants[$0.key] != $0.value }.keys.sorted()
            if !changes.isEmpty { emit(.changesRequested(by: changes.map { names[$0] ?? $0 })) }
            if !approved.isEmpty { emit(.approved(by: approved.map { names[$0] ?? $0 })) }
        }
        // A review request: once, when I am a reviewer who has not reviewed (a draft waits).
        if pr.role == .reviewing, !next.reviewRequestNotified {
            if wantsReview { emit(.reviewRequested(by: pr.author.name)) }
            if wantsReview || pr.myReview != .none { next.reviewRequestNotified = true }
        }
        // Comments by others: grouped, at most one announcement per 10 minutes; what waits is
        // announced with the next one.
        let fresh = othersComments(pr, me: me, after: next.commentsNotifiedAt)
        if !fresh.isEmpty, silent || next.commentEventAt.map({ now - $0 >= commentGap }) ?? true {
            var from: [String] = []
            for comment in fresh.sorted(by: { $0.createdAt < $1.createdAt }) where !from.contains(comment.author.name) { from.append(comment.author.name) }
            emit(.newComments(count: fresh.count, from: from))
            next.commentsNotifiedAt = fresh.map(\.createdAt).max() ?? next.commentsNotifiedAt
            if !silent { next.commentEventAt = now }
        }
        // My build failing: once per failure; the first build state seen is not news.
        if pr.role == .mine, let build = pr.build {
            if !next.buildSeen {
                next.buildSeen = true
                if build.state == .failed { next.buildFailedKey = build.key }
            } else if build.state == .failed, build.key != next.buildFailedKey {
                emit(.buildFailed(pipeline: build.pipeline))
                next.buildFailedKey = build.key
            }
        }
        // Ready to merge: the merge checks went from blocking to all passing; once per head
        // commit. The first reading only records.
        if let ready = pr.isReadyToMerge {
            if ready, next.mergeReady == false, next.readyHead != (pr.head ?? "-") {
                emit(.readyToMerge(approved: pr.merge?.hasApprovalCheck == true))
                next.readyHead = pr.head ?? "-"
            }
            next.mergeReady = ready
        }
        next.role = pr.role
        next.updatedOn = pr.updatedOn
        next.participantsHash = digest
        next.participants = states
        // Moved hourly, so an unchanged pull request leaves its entry (and the file) alone.
        if now - next.aliveAt > 3600 { next.aliveAt = now }
        return (events, next)
    }

    /// What a pull request of mine that left the open list, fetched by id, tells. `fetched` nil:
    /// the fetch failed. Once per pull request: the entry remembers it looked, whatever came back,
    /// so a failure is not retried and a restart does not announce it again.
    static func closed(_ pr: PullRequest, entry: PRSeenEntry?, fetched: [String: Any]?, now: Double) -> (event: PREvent?, entry: PRSeenEntry?) {
        guard pr.role == .mine, entry?.closeChecked != true else { return (nil, entry) }
        // Still open: the list only missed it. It stays unchecked for when it really closes.
        if (fetched?["state"] as? String)?.uppercased() == "OPEN" { return (nil, entry) }
        var next = entry
        next?.closeChecked = true
        guard let fetched, let closure = PRParse.closure(fetched) else { return (nil, next) }
        let kind: PREvent.Kind = closure.merged ? .merged(by: closure.by) : .declined(by: closure.by)
        return (PREvent(kind: kind, pr: pr.ref, title: pr.title, url: pr.url, at: now), next)
    }

    /// Comments by others since I last looked.
    static func newComments(_ pr: PullRequest, entry: PRSeenEntry?, me: String) -> Int {
        guard let entry else { return 0 }
        return othersComments(pr, me: me, after: entry.seenAt).count
    }
}

/// `~/.claude/notch/pr-seen.json` (or `CLAUDE_NOTCH_PR_SEEN`; against a stub, a file in the
/// temporary folder unless that is set, so a test never touches the real one).
enum PRSeenStore {
    struct File: Codable {
        var version = 1
        var entries: [String: PRSeenEntry] = [:]
    }

    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_PR_SEEN"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if BitbucketConfig.isStubbed { return FileManager.default.temporaryDirectory.appendingPathComponent("ai-notch-pr-seen-stub.json") }
        return BitbucketConfig.home.appendingPathComponent(".claude/notch/pr-seen.json")
    }

    /// The entries, and whether the file was there at all (no file: the first look is silent).
    static func load() -> (entries: [String: PRSeenEntry], existed: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([:], false) }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return ([:], true) }
        return (file.entries, true)
    }

    static func save(_ entries: [String: PRSeenEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: The budget

/// The pull-request lane's schedule: mine every 2 minutes (one workspace request; every 5 while
/// the screen is locked), each repository's review list every 10 minutes (20 while one of my
/// pipelines runs, or the screen is locked), stretched so both, with room kept for details, stay
/// under the lane's target of 120 an hour.
enum PRBudget {
    static let mineEvery: Double = 120
    static let mineEveryLocked: Double = 300
    /// Opening the notch reads mine when it is older than this.
    static let openRefresh: Double = 60
    static let reviewEvery: Double = 600
    static let reviewEveryStretched: Double = 1200
    /// Room kept each hour for details (statuses and comments of pull requests that changed).
    static let detailsReserve: Double = 30
    /// A build in progress on one of mine is read again this often (a status does not move
    /// the pull request's updated_on).
    static let buildRecheck: Double = 240
    /// At most this many detail requests in one poll, so a first look spreads out.
    static let detailsPerTick = 6
    /// Merge checks: for my pull requests linked to a live session first, then my newest open
    /// ones, at most `mergeMaxPRs` of them, each read every 15 minutes (5 once its updated_on or
    /// its build moved), never more than `mergePerHour` an hour in all. The hour's room is kept
    /// out of the review lists' share, like the details reserve.
    static let mergeMaxPRs = 4
    static let mergeEvery: Double = 900
    static let mergeEarly: Double = 300
    static let mergePerHour = 18
    /// Reads by id of mine that left the open list (merged or declined?): at most this many an hour.
    static let closedPerHour = 6

    /// The mine request per workspace, stretched so all of them stay under 60 an hour.
    static func mineInterval(workspaces: Int, locked: Bool) -> Double {
        max(locked ? mineEveryLocked : mineEvery, 3600 * Double(max(1, workspaces)) / 60)
    }

    static func reviewInterval(repos: Int, mineWorkspaces: Int, pipelineRunning: Bool, locked: Bool) -> Double {
        let base = pipelineRunning || locked ? reviewEveryStretched : reviewEvery
        let mineCost = Double(max(1, mineWorkspaces)) * 3600 / mineInterval(workspaces: mineWorkspaces, locked: locked)
        let room = max(30, BitbucketLane.pullRequests.hourlyTarget - mineCost - detailsReserve - Double(mergePerHour))
        return max(base, 3600 * Double(max(1, repos)) / room)
    }

    /// The scheduled requests an hour, details aside.
    static func plannedPerHour(repos: Int, mineWorkspaces: Int, pipelineRunning: Bool, locked: Bool) -> Double {
        let mine = Double(max(1, mineWorkspaces)) * 3600 / mineInterval(workspaces: mineWorkspaces, locked: locked)
        let review = Double(repos) * 3600 / reviewInterval(repos: repos, mineWorkspaces: mineWorkspaces, pipelineRunning: pipelineRunning, locked: locked)
        return mine + review
    }
}
