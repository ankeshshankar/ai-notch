import Foundation
import NotchCore

/// `--preview` only: builds and runs from `<sessions>/preview-builds.json` instead of the API
/// and the CLI, reread when the file changes, so a screenshot or a state change (and its
/// notification) needs no real build. Each source the file leaves out runs for real.
///
/// The file holds the sources' own JSON shapes, parsed by their own parsers:
///   {"eas": {"status": null, "cliUser": "sample-user", "builds": [<GraphQL build objects>]},
///    "bitbucket": {"status": {"text": "not connected", "help": "…", "isSetup": true},
///                  "owner": {"uuid": "{…}", "name": "…", "how": "fixture"},
///                  "runs": [<pipeline objects> + "workspace", "repo", "steps": [<step objects>],
///                           "logTail": ["…"], "testCases": {<a test_cases page>},
///                           "usualDuration": 600, "logLine": "…"]},
///    "health": {"eas": "degraded", "easDetail": "…", "bitbucket": null}}
/// A key ending in "Ago" (seconds) stands for that time before now: "createdAgo": 120 →
/// "createdAt" two minutes ago, "created_onAgo" → "created_on".
@MainActor
final class BuildFixtures {
    let url: URL
    private(set) var hasEAS = false
    private(set) var hasBitbucket = false
    private(set) var hasHealth = false
    private var mtime: Double = 0
    private var timer: Timer?
    private var logs: [String: [String]] = [:]
    private var tests: [String: [String]] = [:]
    private var runs: [String: PipelineRun] = [:]
    private var onChange: ((EASSnapshot?, BitbucketSnapshot?, ServiceHealth?) -> Void)?

    private init(url: URL) {
        self.url = url
    }

    static func load() -> BuildFixtures? {
        let url = NotchPaths.sessions.appendingPathComponent("preview-builds.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fixtures = BuildFixtures(url: url)
        // Which sources it stands in for is fixed at launch.
        if let object = fixtures.object() {
            fixtures.hasEAS = object["eas"] != nil
            fixtures.hasBitbucket = object["bitbucket"] != nil
            fixtures.hasHealth = object["health"] != nil
        }
        return fixtures
    }

    func start(_ onChange: @escaping (EASSnapshot?, BitbucketSnapshot?, ServiceHealth?) -> Void) {
        self.onChange = onChange
        reread()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reread() }
        }
    }

    /// A fixture failure's text, from its "logTail" and "testCases", through the same masking.
    func report(for id: String, easURLs: [URL]) -> String? {
        guard id.hasPrefix("bb:"), let run = runs[String(id.dropFirst(3))] else { return nil }
        return BitbucketFailure.compose(run: run, step: run.failedStep, tail: logs[run.id], tests: tests[run.id], easURLs: easURLs)
    }

    private func object() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func reread() {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        guard modified != mtime, let object = object() else { return }
        mtime = modified
        let now = Date().timeIntervalSince1970
        var eas: EASSnapshot?
        if hasEAS, let part = Self.resolve(object["eas"], now: now) as? [String: Any] {
            let builds = (part["builds"] as? [[String: Any]] ?? []).compactMap(EASBuild.parse)
            eas = EASSnapshot(builds: builds.sorted { $0.createdAt > $1.createdAt }, status: Self.status(part["status"]), fetchedAt: now,
                              via: "fixture", cliUser: part["cliUser"] as? String)
        }
        var bitbucket: BitbucketSnapshot?
        if hasBitbucket, let part = Self.resolve(object["bitbucket"], now: now) as? [String: Any] {
            var list: [PipelineRun] = []
            for raw in part["runs"] as? [[String: Any]] ?? [] {
                let repo = BitbucketRepo(workspace: raw["workspace"] as? String ?? "ws", repo: raw["repo"] as? String ?? "repo")
                guard var run = PipelineRun.parse(raw, repo: repo) else { continue }
                run.steps = (raw["steps"] as? [[String: Any]] ?? []).compactMap(PipelineRun.parseStep)
                run.usualDuration = (raw["usualDuration"] as? NSNumber)?.doubleValue
                run.logLine = raw["logLine"] as? String
                logs[run.id] = raw["logTail"] as? [String]
                if let page = raw["testCases"] as? [String: Any] { tests[run.id] = Array(BitbucketFailure.failedTestNames(in: page).prefix(20)) }
                runs[run.id] = run
                list.append(run)
            }
            var owner: BitbucketOwner?
            if let o = part["owner"] as? [String: Any] {
                owner = BitbucketOwner(uuid: o["uuid"] as? String, name: o["name"] as? String, how: o["how"] as? String ?? "fixture")
            }
            bitbucket = BitbucketSnapshot(runs: list.sorted { $0.createdAt > $1.createdAt }, status: Self.status(part["status"]),
                                          fetchedAt: list.isEmpty ? 0 : now, repoCount: Set(list.map { $0.ref.repo }).count,
                                          tokenExpiresAt: (part["tokenExpiresIn"] as? Double).map { now + $0 }, owner: owner)
        }
        var health: ServiceHealth?
        if hasHealth, let part = object["health"] as? [String: Any] {
            health = ServiceHealth(eas: part["eas"] as? String, easDetail: part["easDetail"] as? String,
                                   bitbucket: part["bitbucket"] as? String, bitbucketDetail: part["bitbucketDetail"] as? String)
        }
        onChange?(eas, bitbucket, health)
    }

    private static func status(_ value: Any?) -> SourceStatus? {
        guard let object = value as? [String: Any], let text = object["text"] as? String else { return nil }
        return SourceStatus(text: text, help: object["help"] as? String ?? "", isSetup: object["isSetup"] as? Bool ?? false)
    }

    /// "…Ago": seconds before now → an ISO time under the key without it.
    private static func resolve(_ value: Any?, now: Double) -> Any? {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            let formatter = ISO8601DateFormatter()
            for (key, item) in object {
                if key.hasSuffix("Ago"), let seconds = item as? Double {
                    out[String(key.dropLast(3))] = formatter.string(from: Date(timeIntervalSince1970: now - seconds))
                } else {
                    out[key] = resolve(item, now: now)
                }
            }
            return out
        }
        if let array = value as? [Any] { return array.map { resolve($0, now: now) as Any } }
        return value
    }
}
