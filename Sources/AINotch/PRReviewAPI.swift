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
    static func hasWriteToken() -> Bool { KeychainItem.read(service: writeService) != nil }

    /// What Bitbucket says now, right before a click is carried out.
    struct Fresh: Equatable {
        var isOpen: Bool
        var head: String?
        var pipeline: PipelineState
        var alreadyApproved: Bool
    }

    /// The pull request and its builds, read now with the read token (never the write one).
    static func fresh(_ ref: PullRequestRef, me: String?) async -> Fresh? {
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
