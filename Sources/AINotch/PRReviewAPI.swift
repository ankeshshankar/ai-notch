import Foundation
import ReviewCore

/// The only writes to Bitbucket the notch can make: approve and request changes on a pull
/// request I review, with a write token of its own (Keychain `ai-notch.bitbucket.write`, scope
/// `pullrequest:write`), only after a click and a confirm. Both endpoints and their scope are
/// from Atlassian's published OpenAPI (api.bitbucket.org/swagger.json, checked 2026-11-25):
/// `POST /2.0/repositories/{workspace}/{repo_slug}/pullrequests/{id}/approve` and
/// `…/request-changes`, each `pullrequest:write`. Nothing else is ever posted: no comments, no
/// merge, no decline; the review's drafted comments stay in its report.
enum PRReviewAPI {
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
}
