import Foundation
import ReviewCore

/// Dev only: `--review-full-live <workspace> <repo> <pr> <head> <folder> [--replay-blind]` runs the real full-review
/// pipeline (same checkout, prompt, arguments, skill and agent files, allow-list) on a chosen commit, writing only into
/// `<folder>`. It never touches the real reviews folder, the ledger, notifications or Bitbucket writes (the read token
/// reaches the child as for any review; nothing here posts). `--replay-blind` keeps other people's comments out of the run.
extension PRReviewDev {
    static func liveFull(workspace: String, repo: String, pr: Int, head: String, folder: String, blind: Bool) -> Int32 {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let ref = PullRequestRef(workspace: workspace, repo: repo, id: pr)
        guard !PRReviewStore.isRealFolder(dir) else { print("refused: the folder is inside the real reviews folder"); return 2 }
        guard let clone = PRReviewStore.repoPath(ref) else { print("failed: no local clone is set for \(workspace)/\(repo)"); return 1 }
        guard let token = KeychainItem.read(service: BitbucketConfig.tokenService)?.secret else { print("failed: no Bitbucket read token"); return 1 }
        // The commit may be gone from the branch (moved on or merged): fetch it by sha when the clone lacks it.
        func has() -> Bool { runProcess("/usr/bin/git", ["-C", clone, "cat-file", "-e", head + "^{commit}"], timeout: 30)?.status == 0 }
        if !has() { _ = runProcess("/usr/bin/git", ["-C", clone, "fetch", "--quiet", "origin", head], timeout: 300) }
        if !has() { _ = runProcess("/usr/bin/git", ["-C", clone, "fetch", "--quiet", "origin"], timeout: 300) }
        guard has() else { print("failed: commit \(head) is not in the clone and could not be fetched"); return 1 }

        var job = PRReviewRunner.Job(ref: ref, head: head, repoPath: clone, dir: dir, token: token)
        job.replayLines = ReplayPrompt.lines(head: head, blind: blind)
        let started = Date()
        let result = PRReviewRunner().runSync(job)
        let minutes = Date().timeIntervalSince(started) / 60
        switch result {
        case .finished(let out):
            print(summary(out, dir: dir, minutes: minutes))
            return out.isError ? 1 : 0
        case .failed(let m): print("failed: \(m)"); return 1
        case .cancelled: print("cancelled"); return 1
        case .timedOut(let stopped): print("timed out: \(stopped.text); elapsed \(String(format: "%.1f", stopped.elapsed / 60)) min; out.json records it"); return 1
        }
    }

    /// gate, verdict, findings by severity, files read / files, cost, minutes, subagents by type and model.
    static func summary(_ out: ReviewOutput, dir: URL, minutes: Double) -> String {
        func json(_ name: String) -> Any? { (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        let report = (try? String(contentsOf: dir.appendingPathComponent("review.md"), encoding: .utf8)) ?? out.text
        let parsed = ReviewParse.parse(report)
        let gate = (json("gate.json") as? [String: Any])?["gate"] as? String ?? "none"
        let files = ((json("ledger.json") as? [String: Any])?["files"] as? [[String: Any]]) ?? []
        let read = files.filter { ($0["read"] as? Bool) == true }.count
        let drops = (json("drops.json") as? [Any])?.count ?? 0
        let cost = out.costUSD.map { String(format: "%.2f", $0) } ?? "?"
        return "gate \(gate); verdict \(parsed?.verdict.rawValue ?? "none"); findings \(parsed?.findings.text ?? "?"); drops \(drops); files read \(read)/\(files.count); cost \(cost) USD; "
            + String(format: "%.1f min; ", minutes) + "subagents \(subagents(sessionID: out.sessionID)); denied \(out.denied.isEmpty ? "none" : out.denied.joined(separator: ","))"
    }

    /// Agent calls in the session's transcript, counted by type and model (the model the call named, else the agent file's).
    static func subagents(sessionID: String?) -> String {
        guard let sessionID else { return "unknown" }
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path),
              let file = dirs.map({ root.appendingPathComponent($0).appendingPathComponent(sessionID + ".jsonl") }).first(where: { fm.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return "unknown" }
        let names = ReviewNames.load()
        var defaults: [String: String] = [:]
        for name in [names.lens, names.verifier] {
            if let body = try? String(contentsOfFile: fm.homeDirectoryForCurrentUser.path + "/.claude/agents/\(name).md", encoding: .utf8) {
                defaults[name] = ReviewAgents.parts(of: body).meta["model"] ?? "inherit"
            }
        }
        return countAgents(in: text, defaults: defaults)
    }

    /// The Agent calls of a transcript, by type and model, each call once (see the note on the double count).
    static func countAgents(in text: String, defaults: [String: String]) -> String {
        var counts: [String: Int] = [:]
        // The transcript also holds `api-request-blob` lines that replay earlier requests, tool_use blocks included:
        // only the assistant's own lines count, and each call once by its id (that doubled the count: 22 for 12).
        var seen = Set<String>()
        for line in text.split(separator: "\n") where line.contains("\"tool_use\"") {
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { continue }
            for item in content where item["type"] as? String == "tool_use" && ["Agent", "Task"].contains(item["name"] as? String ?? "") {
                if let id = item["id"] as? String, !seen.insert(id).inserted { continue }
                let input = item["input"] as? [String: Any] ?? [:]
                let type = input["subagent_type"] as? String ?? "general"
                counts["\(type):\(input["model"] as? String ?? defaults[type] ?? "inherit")", default: 0] += 1
            }
        }
        return counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
    }
}
