import Foundation
import ReviewCore

/// The only writes to Bitbucket the notch can make: approve and request changes on a pull
/// request I review, with a write token of its own (Keychain `ai-notch.bitbucket.write`, scope
/// `pullrequest:write`), only after a click and a confirm. Both endpoints and their scope are
/// from Atlassian's published OpenAPI (api.bitbucket.org/swagger.json, checked 2026-11-25):
/// `POST /2.0/repositories/{workspace}/{repo_slug}/pullrequests/{id}/approve` and
/// `…/request-changes`, each `pullrequest:write`. Nothing else is ever posted: no comments, no
/// merge, no decline. Comments are posted only from the review window's "Post N comments", after
/// a confirm that lists them: `POST …/pullrequests/{id}/comments` (`pullrequest:write`, the same
/// token). With `AI_NOTCH_REVIEW_DRYRUN=1` nothing leaves the machine: each request that would be
/// sent is recorded in `PRReviewAPI.sent` instead, and answers as a success.
enum PRReviewAPI {
    /// A request the dry run recorded instead of sending.
    struct Sent: Equatable, Sendable {
        var method: String
        var url: String
        var body: String
    }

    nonisolated(unsafe) static var sent: [Sent] = []
    nonisolated(unsafe) static var forceDryRun = false
    static var dryRun: Bool { forceDryRun || ProcessInfo.processInfo.environment["AI_NOTCH_REVIEW_DRYRUN"] == "1" }

    static let writeService = "ai-notch.bitbucket.write"
    /// The command Setup shows: the token from the clipboard, which is then cleared.
    static let saveCommand = "security add-generic-password -U -s \(writeService) -a api-token -j \"expires YYYY-MM-DD\" -w \"$(pbpaste)\" && pbcopy < /dev/null"

    /// Whether the write token is stored (off the main thread: `security` runs).
    static func hasWriteToken() -> Bool { dryRun || KeychainItem.read(service: writeService) != nil }

    /// What Bitbucket says now, right before a click is carried out.
    struct Fresh: Equatable {
        var isOpen: Bool
        var head: String?
        var pipeline: PipelineState
        var alreadyApproved: Bool
    }

    /// The pull request and its builds, read now with the read token (never the write one).
    /// A preview or check answers with this instead of reading Bitbucket.
    nonisolated(unsafe) static var fixtureFresh: Fresh?

    static func fresh(_ ref: PullRequestRef, me: String?) async -> Fresh? {
        if let fixtureFresh { return fixtureFresh }
        guard let read = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else { return nil }
        let base = "\(BitbucketConfig.apiBase)/repositories/\(ref.workspace)/\(ref.repo)/pullrequests/\(ref.id)"
        guard let prURL = BuildHTTP.url(base, [("fields", "state,source.commit.hash,participants.state,participants.approved,participants.user.uuid")]),
              let statusURL = BuildHTTP.url(base + "/statuses", [("pagelen", "20"), ("fields", PRParse.statusFields)]),
              let pr = await getJSON(prURL, token: read), let statuses = await getJSON(statusURL, token: read) else { return nil }
        let head = ((pr["source"] as? [String: Any])?["commit"] as? [String: Any])?["hash"] as? String
        let mine = (pr["participants"] as? [[String: Any]] ?? []).first { ($0["user"] as? [String: Any])?["uuid"] as? String == me && me != nil }
        let approved = mine?["approved"] as? Bool == true || (mine?["state"] as? String)?.lowercased() == "approved"
        let pipeline: PipelineState
        switch PRParse.build(statuses)?.state {
        case .succeeded?: pipeline = .green
        case nil: pipeline = .unknown
        default: pipeline = .notGreen
        }
        return Fresh(isOpen: (pr["state"] as? String)?.uppercased() == "OPEN", head: head, pipeline: pipeline, alreadyApproved: approved)
    }

    enum SendResult: Equatable {
        case done
        case failed(String)
    }

    static func send(_ action: ReviewAction, to ref: PullRequestRef) async -> SendResult {
        if dryRun {
            sent.append(Sent(method: "POST", url: "\(BitbucketConfig.apiBase)/repositories/\(ref.workspace)/\(ref.repo)/pullrequests/\(ref.id)/\(action == .approve ? "approve" : "request-changes")", body: ""))
            return .done
        }
        guard let write = KeychainItem.read(service: writeService)?.secret else {
            return .failed("no write token: add it in Setup → Pull requests")
        }
        let path = action == .approve ? "approve" : "request-changes"
        guard let url = URL(string: "\(BitbucketConfig.apiBase)/repositories/\(ref.workspace)/\(ref.repo)/pullrequests/\(ref.id)/\(path)") else {
            return .failed("bad address")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(write)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await BuildHTTP.session.data(for: request), let http = response as? HTTPURLResponse else {
            return .failed("no answer from Bitbucket")
        }
        switch http.statusCode {
        case 200, 201, 204: return .done
        case 401: return .failed("the write token was rejected")
        case 403: return .failed(PRParse.isScopeError(data) ? "the write token lacks the pullrequest:write scope" : "not allowed on this pull request")
        case 404: return .failed("pull request not found")
        default: return .failed("Bitbucket answered \(http.statusCode)")
        }
    }

    private static func getJSON(_ url: URL, token: String) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await BuildHTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Comments

    /// The pull request's comments, read with the read token (never the write one): at most 5 pages of 100.
    static func comments(_ ref: PullRequestRef) async -> [ExistingComment]? {
        if let fixture = fixtureComments { return fixture }
        guard let read = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else { return nil }
        let base = CommentPayload.endpoint(apiBase: BitbucketConfig.apiBase, workspace: ref.workspace, repo: ref.repo, id: ref.id)
        let query = [("pagelen", "100"), ("fields", ExistingComments.fields)]
        var url = BuildHTTP.url(base, query)
        var all: [ExistingComment] = []
        for _ in 0..<5 {
            guard let current = url else { break }
            var request = URLRequest(url: current, timeoutInterval: 30)
            request.setValue("Bearer \(read)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await BuildHTTP.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let page = ExistingComments.parse(data) else { return all.isEmpty ? nil : all }
            all += page.comments
            url = page.next.flatMap { BuildHTTP.next($0, keeping: query) }
        }
        return all
    }

    /// A review window preview or check answers with these instead of reading Bitbucket.
    nonisolated(unsafe) static var fixtureComments: [ExistingComment]?

    /// The comments with their parents and authors, for the reply threads (same read token, same paging).
    /// A preview or check answers with `fixtureRaw`.
    nonisolated(unsafe) static var fixtureRaw: [RawComment]?

    static func rawComments(_ ref: PullRequestRef) async -> [RawComment]? {
        if let fixtureRaw { return fixtureRaw }
        guard fixtureComments == nil, let read = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else { return nil }
        let base = CommentPayload.endpoint(apiBase: BitbucketConfig.apiBase, workspace: ref.workspace, repo: ref.repo, id: ref.id)
        let query = [("pagelen", "100"), ("fields", CommentPages.fields)]
        var url = BuildHTTP.url(base, query)
        var all: [RawComment] = []
        for _ in 0..<5 {
            guard let current = url else { break }
            var request = URLRequest(url: current, timeoutInterval: 30)
            request.setValue("Bearer \(read)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await BuildHTTP.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let page = CommentPages.parse(data) else { return all.isEmpty ? nil : all }
            all += page.comments
            url = page.next.flatMap { BuildHTTP.next($0, keeping: query) }
        }
        return all
    }

    enum PostResult: Equatable {
        case posted(Int)
        case failed(String)
    }

    /// One comment, after the click and the confirm in the review window. Inline on its file and
    /// line, or general when it has none.
    static func post(_ card: SuggestedComment, to ref: PullRequestRef) async -> PostResult {
        let body = CommentPayload.json(for: card)
        let endpoint = CommentPayload.endpoint(apiBase: BitbucketConfig.apiBase, workspace: ref.workspace, repo: ref.repo, id: ref.id)
        if dryRun {
            sent.append(Sent(method: "POST", url: endpoint, body: String(decoding: body, as: UTF8.self)))
            return .posted(900_000 + sent.count)
        }
        guard let write = KeychainItem.read(service: writeService)?.secret else {
            return .failed("no write token: add it in Setup → Pull requests")
        }
        guard let url = URL(string: endpoint) else { return .failed("bad address") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(write)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await BuildHTTP.session.data(for: request), let http = response as? HTTPURLResponse else {
            return .failed("no answer from Bitbucket")
        }
        switch http.statusCode {
        case 200, 201:
            guard let id = CommentPayload.createdID(data) else { return .failed("Bitbucket did not return the comment") }
            return .posted(id)
        case 401: return .failed("the write token was rejected")
        case 403: return .failed(PRParse.isScopeError(data) ? "the write token lacks the pullrequest:write scope" : "not allowed on this pull request")
        case 404: return .failed("pull request not found")
        case 400: return .failed("Bitbucket refused the comment (is that line in the diff?)")
        default: return .failed("Bitbucket answered \(http.statusCode)")
        }
    }
}

extension PRReviewAPI {
    struct BranchInfo: Equatable, Sendable, Hashable {
        var name: String
        var head: String
    }

    struct BranchList: Equatable, Sendable {
        var branches: [BranchInfo]
        var main: String?
    }

    /// A preview or check answers with this instead of reading Bitbucket.
    nonisolated(unsafe) static var fixtureBranches: BranchList?

    /// The newest branches of a repository (at most 100) and its main branch, read with the read token.
    static func branches(repoKey: String) async -> BranchList? {
        if let fixtureBranches { return fixtureBranches }
        guard let read = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else { return nil }
        let base = "\(BitbucketConfig.apiBase)/repositories/\(repoKey)"
        guard let listURL = BuildHTTP.url(base + "/refs/branches", [("pagelen", "100"), ("sort", "-target.date"), ("fields", "values.name,values.target.hash")]),
              let repoURL = BuildHTTP.url(base, [("fields", "mainbranch.name")]),
              let list = await getJSON(listURL, token: read) else { return nil }
        let main = (await getJSON(repoURL, token: read))?["mainbranch"] as? [String: Any]
        let branches: [BranchInfo] = (list["values"] as? [[String: Any]] ?? []).compactMap { value in
            guard let name = value["name"] as? String, let hash = (value["target"] as? [String: Any])?["hash"] as? String, ReviewBranch.isValid(name) else { return nil }
            return BranchInfo(name: name, head: hash)
        }
        return BranchList(branches: branches, main: main?["name"] as? String)
    }

    enum TaskResult: Equatable {
        case created(Int)
        case failed(String)
    }

    /// A task linked to a comment I just posted (`POST …/tasks`, `pullrequest:write`; the endpoint and body are from
    /// Atlassian's OpenAPI: `{"content": {"raw": …}, "comment": {"id": …}}`). Only after the same confirm as the comment.
    static func createTask(for card: SuggestedComment, commentID: Int, to ref: PullRequestRef) async -> TaskResult {
        let body = TaskPayload.json(for: card, commentID: commentID)
        let endpoint = TaskPayload.endpoint(apiBase: BitbucketConfig.apiBase, workspace: ref.workspace, repo: ref.repo, id: ref.id)
        if dryRun {
            sent.append(Sent(method: "POST", url: endpoint, body: String(decoding: body, as: UTF8.self)))
            return .created(800_000 + sent.count)
        }
        switch await write(endpoint, body: body) {
        case .failure(let why): return .failed(why.text)
        case .success(let data): return CommentPayload.createdID(data).map { .created($0) } ?? .failed("Bitbucket did not return the task")
        }
    }

    /// Resolves a comment thread (`POST …/comments/{id}/resolve`, no body): only from the Resolve button, after a confirm.
    /// 409 means it was already resolved, which is what was asked for.
    static func resolve(commentID: Int, on ref: PullRequestRef) async -> SendResult {
        let endpoint = ResolvePayload.endpoint(apiBase: BitbucketConfig.apiBase, workspace: ref.workspace, repo: ref.repo, id: ref.id, commentID: commentID)
        if dryRun {
            sent.append(Sent(method: "POST", url: endpoint, body: ""))
            return .done
        }
        switch await write(endpoint, body: nil, okStatus: [200, 201, 204, 409]) {
        case .failure(let why): return .failed(why.text == "Bitbucket answered 403" ? "only a comment thread's first comment can be resolved" : why.text)
        case .success: return .done
        }
    }

    /// Posts a reply under one of my comments (`POST …/comments` with a `parent`): only from the Reply buttons, after a confirm.
    /// The id Bitbucket gave the new comment (the dry run answers 900_001 and up).
    static func reply(to parent: Int, text: String, on ref: PullRequestRef) async -> PostResult {
        let endpoint = CommentPayload.endpoint(apiBase: BitbucketConfig.apiBase, workspace: ref.workspace, repo: ref.repo, id: ref.id)
        let body = ReplyPayload.json(parent: parent, body: text)
        if dryRun {
            sent.append(Sent(method: "POST", url: endpoint, body: String(decoding: body, as: UTF8.self)))
            return .posted(900_001 + sent.count)
        }
        switch await write(endpoint, body: body) {
        case .failure(let why): return .failed(why.text)
        case .success(let data): return CommentPayload.createdID(data).map { .posted($0) } ?? .failed("Bitbucket did not return the reply")
        }
    }

    private static func write(_ endpoint: String, body: Data?, okStatus: Set<Int> = [200, 201, 204]) async -> Result<Data, WriteFailure> {
        guard let write = KeychainItem.read(service: writeService)?.secret else { return .failure(WriteFailure("no write token: add it in Setup → Pull requests")) }
        guard let url = URL(string: endpoint) else { return .failure(WriteFailure("bad address")) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(write)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, response) = try? await BuildHTTP.session.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure(WriteFailure("no answer from Bitbucket"))
        }
        if okStatus.contains(http.statusCode) { return .success(data) }
        switch http.statusCode {
        case 401: return .failure(WriteFailure("the write token was rejected"))
        case 403 where PRParse.isScopeError(data): return .failure(WriteFailure("the write token lacks the pullrequest:write scope"))
        case 404: return .failure(WriteFailure("not found"))
        default: return .failure(WriteFailure("Bitbucket answered \(http.statusCode)"))
        }
    }

    /// A failed write's reason, as an Error for `Result`.
    struct WriteFailure: Error, Equatable {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// A preview or check answers with this instead of counting commits on Bitbucket.
    nonisolated(unsafe) static var fixtureBehind: Int?

    /// How many commits the pull request gained since the reviewed one (the API lists them with
    /// `include` and `exclude`); nil when it cannot be told. 100 is the most counted.
    static func commitsSince(_ ref: PullRequestRef, reviewed: String, head: String) async -> Int? {
        if let fixtureBehind { return fixtureBehind }
        guard let read = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret,
              let url = BuildHTTP.url("\(BitbucketConfig.apiBase)/repositories/\(ref.workspace)/\(ref.repo)/commits",
                                      [("include", head), ("exclude", reviewed), ("pagelen", "100"), ("fields", "values.hash")]) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(read)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await BuildHTTP.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let values = object["values"] as? [Any] else { return nil }
        return values.count
    }
}
