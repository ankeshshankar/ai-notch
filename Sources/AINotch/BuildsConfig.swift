import Foundation

/// The Pipelines section's settings, from `~/.claude/notch/builds.json` (or the file
/// `CLAUDE_NOTCH_BUILDS_CONFIG` names, for a test). Nothing about a project is built in: with no
/// file, or a file without a part, that source does not run and the section stays hidden.
///
///     {
///       "eas": {
///         "account": "acme",                      the Expo account that owns the project
///         "slug": "mobile-app",                   the project's slug
///         "projectId": "<uuid>",                  extra.eas.projectId in its app config
///         "cli": "~/src/mobile-app/node_modules/.bin/eas"   optional: the eas-cli to fall back on
///       },
///       "bitbucket": {
///         "workspace": "acme",                    for plain repository names below
///         "repos": ["mobile-app", "other-ws/api"],
///         "searchRoots": ["~/src"],               optional: also every local clone under these
///         "pullRequests": true                    optional: my PRs and review requests (default on)
///       },
///       "me": { "emails": ["you@example.com"] },  optional: else your git user.email
///       "datadog": { "site": "us3", "monitors": "<monitor search>", …}   the footer's Prod chip
///                                                 (DatadogConfig.example has all of it)
///       "machine": { "warnBelowMB": 4096, "idleMinutes": 15, "exclude": [] }   optional: the RAM chip
///       "agents": { "watch": { "mybot": "My Bot" }, "ignore": ["amp"] }   optional: the agent
///                                                 process watcher's extra names and the ones it skips
///     }
///
/// A repository is "name" (in `workspace`), "workspace/name", or {"workspace", "repo", "path"}.
/// The file is read again when it changes (checked at most every few seconds).
struct BuildsConfig: Equatable, Sendable {
    struct EAS: Equatable, Sendable {
        var account: String
        var slug: String
        var projectId: String
        /// An eas-cli to run when the GraphQL API fails (tilde expanded).
        var cli: String?
    }

    struct Bitbucket: Equatable, Sendable {
        var workspace: String?
        var repos: [BitbucketRepo]
        /// Folders whose clones with a bitbucket.org remote and a bitbucket-pipelines.yml join
        /// the list (tilde expanded).
        var searchRoots: [String]
        /// Read my pull requests and review requests in these repositories (PullRequestSource);
        /// on unless `"pullRequests": false`.
        var pullRequests = true
    }

    /// Prod health: Datadog monitors, incidents and a few numbers (Datadog.swift).
    struct Datadog: Equatable, Sendable {
        /// A number in the footer: one metrics query, or several named ones and a formula.
        struct Health: Equatable, Sendable {
            struct Query: Equatable, Sendable {
                var name: String
                var query: String
            }
            var label: String
            var queries: [Query]
            var formula: String
            /// How the window collapses to one value: avg, sum, min, max, last, percentile…
            var aggregator: String
            /// Shown after the value ("%", "ms"); `scale` multiplies the raw value first (seconds
            /// to ms: 1000). Above `amber` (in shown units) the chip turns amber.
            var unit: String
            var scale: Double
            var amber: Double?
            /// Seconds back from now.
            var window: Double
        }

        /// The site's domain: "us3.datadoghq.com", "datadoghq.com", "datadoghq.eu".
        var site: String
        /// A monitor search query, as the Manage Monitors page's search box takes it.
        var monitors: String
        /// An incident search query; nil leaves incidents out.
        var incidents: String?
        var health: [Health]
        /// Repository (lowercased "workspace/repo", the repo name, or its folder name) → the Datadog
        /// service it deploys as. A repo with no entry gets no deploy check.
        var services: [String: DeployLink] = [:]
        /// Services left out of Prod entirely: monitors, incidents, deploy checks, Watchdog (lowercased).
        /// "leads*" is "leads" and every "leads-…"; a plain name is that service alone.
        var hiddenServices: [String] = Datadog.defaultHidden
        /// Read Datadog Watchdog stories; on unless `"watchdog": false`.
        var watchdog = true

        static let defaultHidden = ["leads*"]
    }

    var eas: EAS?
    var bitbucket: Bitbucket?
    var datadog: Datadog?
    /// The machine guard's settings; it runs with the defaults without them.
    var machine: MachineConfig?
    /// The agent watcher's extra process names (name → what to call it) and names it skips.
    var watchAgents: [String: String] = [:]
    var ignoreAgents: Set<String> = []
    /// Whose runs are mine: these commit emails, else the git identity.
    var emails: [String] = []
    var name: String?
    /// What in the file could not be used, in a few words each.
    var problems: [String] = []

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var file: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILDS_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return home.appendingPathComponent(".claude/notch/builds.json")
    }

    /// The path with the home folder as `~`, for text.
    static var displayPath: String { file.path.replacingOccurrences(of: home.path, with: "~") }

    /// An example to start from: Setup shows it and the README repeats it.
    static let example = """
    {
      "eas": {
        "account": "acme",
        "slug": "mobile-app",
        "projectId": "your-project-id"
      },
      "bitbucket": {
        "workspace": "acme",
        "repos": ["mobile-app", "api"],
        "searchRoots": ["~/Code"]
      }
    }
    """

    // MARK: Reading

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var checkedAt: Double = -.infinity
        var stamp: Date?
        var exists = false
        var config: BuildsConfig?
        var discovered: (at: Double, key: String, repos: [BitbucketRepo])?
    }

    private static let cache = Cache()

    /// The settings now, or nil when there is no usable file. Cheap: the file is looked at
    /// again at most every 3 seconds, and parsed only when it changed. Any thread.
    static var current: BuildsConfig? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let now = Date().timeIntervalSince1970
        if now - cache.checkedAt < 3 { return cache.config }
        cache.checkedAt = now
        let manager = FileManager.default
        if !manager.fileExists(atPath: file.path), !cache.exists { migrateIfNeeded() }
        let stamp = (try? manager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let exists = stamp != nil
        if exists == cache.exists, stamp == cache.stamp { return cache.config }
        cache.exists = exists
        cache.stamp = stamp
        cache.config = exists ? (try? Data(contentsOf: file)).flatMap(parse) : nil
        cache.discovered = nil
        return cache.config
    }

    /// Forgets what was read, so the next look reads the file (Setup's Check Again).
    static func reload() {
        cache.lock.lock()
        cache.checkedAt = -.infinity
        cache.stamp = nil
        cache.discovered = nil
        cache.lock.unlock()
    }

    /// Whether the file is there at all, usable or not.
    static var fileExists: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func parse(_ data: Data) -> BuildsConfig? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BuildsConfig(problems: ["not valid JSON"])
        }
        var config = BuildsConfig()
        if let eas = object["eas"] as? [String: Any] {
            let account = string(eas["account"]) ?? string(eas["owner"])
            let slug = string(eas["slug"]) ?? string(eas["project"])
            let projectId = string(eas["projectId"])
            if let account, let slug, let projectId {
                config.eas = EAS(account: account, slug: slug, projectId: projectId, cli: string(eas["cli"]).map(expand))
            } else {
                config.problems.append("eas needs account, slug and projectId")
            }
        }
        if let bitbucket = object["bitbucket"] as? [String: Any] {
            let workspace = string(bitbucket["workspace"])
            var repos: [BitbucketRepo] = []
            for item in bitbucket["repos"] as? [Any] ?? [] {
                var repo: BitbucketRepo?
                if let text = string(item) {
                    let parts = text.split(separator: "/").map(String.init)
                    if parts.count == 2 { repo = BitbucketRepo(workspace: parts[0], repo: parts[1]) }
                    else if parts.count == 1, let workspace { repo = BitbucketRepo(workspace: workspace, repo: parts[0]) }
                } else if let entry = item as? [String: Any], let name = string(entry["repo"]),
                          let space = string(entry["workspace"]) ?? workspace {
                    repo = BitbucketRepo(workspace: space, repo: name, path: string(entry["path"]).map(expand))
                }
                if let repo, !repos.contains(where: { $0.key == repo.key }) { repos.append(repo) }
                else if repo == nil { config.problems.append("bitbucket repo \(String(describing: item)) needs a workspace") }
            }
            let roots = (bitbucket["searchRoots"] as? [Any] ?? []).compactMap(string).map(expand)
            if !repos.isEmpty || !roots.isEmpty {
                config.bitbucket = Bitbucket(workspace: workspace, repos: repos, searchRoots: roots,
                                             pullRequests: bitbucket["pullRequests"] as? Bool ?? true)
            } else {
                config.problems.append("bitbucket needs repos or searchRoots")
            }
        }
        if let datadog = object["datadog"] as? [String: Any] {
            if let monitors = string(datadog["monitors"]) {
                let incidents: String? = (datadog["incidents"] as? Bool) == false ? nil : string(datadog["incidents"]) ?? "state:active"
                var health: [Datadog.Health] = []
                for (index, item) in (datadog["health"] as? [Any] ?? []).prefix(3).enumerated() {
                    guard let entry = item as? [String: Any] else { continue }
                    let label = string(entry["label"]) ?? "#\(index + 1)"
                    var queries: [Datadog.Health.Query] = []
                    var formula = string(entry["formula"])
                    if let query = string(entry["query"]) {
                        queries = [.init(name: "a", query: query)]
                        formula = formula ?? "a"
                    } else if let named = entry["queries"] as? [String: Any] {
                        queries = named.keys.sorted().compactMap { name in
                            string(named[name]).map { Datadog.Health.Query(name: name, query: $0) }
                        }
                    }
                    guard !queries.isEmpty, let formula else {
                        config.problems.append("datadog health \(label) needs query, or queries and formula")
                        continue
                    }
                    health.append(Datadog.Health(label: label, queries: queries, formula: formula,
                                                 aggregator: string(entry["aggregator"]) ?? "avg",
                                                 unit: string(entry["unit"]) ?? "", scale: number(entry["scale"]) ?? 1,
                                                 amber: number(entry["amber"]), window: (number(entry["minutes"]) ?? 15) * 60))
                }
                var parsed = Datadog(site: DatadogConfig.domain(string(datadog["site"]) ?? "datadoghq.com"),
                                     monitors: monitors, incidents: incidents, health: health)
                // services: { "<repo>": "<service>" } or { "<repo>": { "service": "...", "operation": "express.request" } }.
                for (repo, value) in (datadog["services"] as? [String: Any] ?? [:]) {
                    let entry = value as? [String: Any]
                    let service = (entry?["service"] ?? value) as? String
                    let operation = entry?["operation"] as? String
                    guard let service = service.flatMap(DeployLink.clean), !repo.isEmpty,
                          operation == nil || operation.flatMap(DeployLink.clean) != nil else {
                        config.problems.append("datadog services \(repo) needs a service name")
                        continue
                    }
                    parsed.services[repo.lowercased()] = DeployLink(service: service, operation: operation.flatMap(DeployLink.clean) ?? DeployLink.defaultOperation)
                }
                if let hidden = datadog["hiddenServices"] as? [Any] {
                    parsed.hiddenServices = hidden.compactMap(string).map { $0.lowercased() }
                }
                parsed.watchdog = datadog["watchdog"] as? Bool ?? true
                config.datadog = parsed
            } else {
                config.problems.append("datadog needs monitors (a monitor search query)")
            }
        }
        if let machine = object["machine"] as? [String: Any] {
            var settings = MachineConfig()
            if let below = MachineConfig.number(machine["warnBelowMB"]), below >= 0 { settings.warnBelowMB = Int(below) }
            if let minutes = MachineConfig.number(machine["idleMinutes"]), minutes >= 1 { settings.idleMinutes = Int(minutes) }
            for item in machine["exclude"] as? [Any] ?? [] {
                if let name = string(item), let kind = MachineKind(rawValue: name) {
                    settings.exclude.insert(kind)
                } else {
                    config.problems.append("machine exclude \(String(describing: item)) is not one of \(MachineKind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
            }
            config.machine = settings
        }
        if let agents = object["agents"] as? [String: Any] {
            if let named = agents["watch"] as? [String: Any] {
                for (process, title) in named { config.watchAgents[process] = string(title) ?? process }
            } else {
                for item in agents["watch"] as? [Any] ?? [] { if let process = string(item) { config.watchAgents[process] = process } }
            }
            config.ignoreAgents = Set((agents["ignore"] as? [Any] ?? []).compactMap(string))
        }
        if let me = object["me"] as? [String: Any] {
            let emails = (me["emails"] as? [Any] ?? []).compactMap(string) + [string(me["email"])].compactMap { $0 }
            config.emails = emails.map { $0.lowercased() }
            config.name = string(me["name"])
        }
        return config
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// A JSON number (or a numeric string); `true`/`false` are not numbers. `value is Bool` cannot
    /// tell: it is true for any NSNumber 0 or 1, so the JSON boolean's own type is checked.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    static func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }

    // MARK: Writing

    /// Setup's pull-requests switch: `"pullRequests": false` in the bitbucket part, or the key
    /// taken out (on is the default). The rest of the file keeps its keys, order and numbers;
    /// it is written atomically, and only when it changes. Returns why it could not, or nil.
    static func setPullRequests(_ on: Bool, in file: URL = BuildsConfig.file) -> String? {
        guard let data = try? Data(contentsOf: file) else { return "no \(displayPath)" }
        guard var root = try? OrderedJSON.parse(data), root.members != nil else { return "\(displayPath) is not valid JSON" }
        guard var bitbucket = root["bitbucket"], bitbucket.members != nil else { return "no bitbucket part in \(displayPath)" }
        bitbucket["pullRequests"] = on ? nil : .bool(false)
        root["bitbucket"] = bitbucket
        var text = root.serialized()
        if data.last == UInt8(ascii: "\n") { text += "\n" }
        let next = Data(text.utf8)
        guard next != data else { return nil }
        do {
            try next.write(to: file, options: .atomic)
        } catch {
            return "could not write \(displayPath)"
        }
        reload()
        noteBuildLog("builds: pull requests turned \(on ? "on" : "off") in \(displayPath)")
        return nil
    }

    // MARK: Bitbucket repositories

    /// The listed repositories, then the clones found under the search roots (in the workspace,
    /// when one is set). Discovery is cached for 5 minutes; with `scan` false (the main thread)
    /// only what the poller last found is used. Any thread.
    static func bitbucketRepos(_ config: Bitbucket, scan: Bool = true) -> [BitbucketRepo] {
        var repos = config.repos
        guard !config.searchRoots.isEmpty else { return repos }
        let key = config.searchRoots.joined(separator: "\n") + "|" + (config.workspace ?? "")
        let now = Date().timeIntervalSince1970
        cache.lock.lock()
        let cached = cache.discovered
        cache.lock.unlock()
        let found: [BitbucketRepo]
        if let cached, cached.key == key, now - cached.at < 300 || !scan {
            found = cached.repos
        } else if !scan {
            found = []
        } else {
            found = discover(roots: config.searchRoots).filter { config.workspace == nil || $0.workspace == config.workspace }
            cache.lock.lock()
            cache.discovered = (now, key, found)
            cache.lock.unlock()
        }
        for repo in found {
            if let index = repos.firstIndex(where: { $0.key == repo.key }) {
                if repos[index].path == nil { repos[index].path = repo.path }
            } else {
                repos.append(repo)
            }
        }
        return repos
    }

    /// Git clones under the roots (the root itself and up to three levels down, skipping hidden
    /// folders and node_modules) with a bitbucket.org remote and a bitbucket-pipelines.yml, from
    /// their `.git/config` (read, never run).
    static func discover(roots: [String]) -> [BitbucketRepo] {
        let manager = FileManager.default
        var repos: [BitbucketRepo] = []
        var visited = 0
        func visit(_ dir: URL, depth: Int) {
            guard visited < 3000 else { return }
            visited += 1
            let config = dir.appendingPathComponent(".git/config")
            if manager.fileExists(atPath: config.path) {
                if manager.fileExists(atPath: dir.appendingPathComponent("bitbucket-pipelines.yml").path),
                   let text = try? String(contentsOf: config, encoding: .utf8),
                   let remote = bitbucketRemote(in: text) {
                    let item = BitbucketRepo(workspace: remote.workspace, repo: remote.repo, path: dir.path)
                    if !repos.contains(where: { $0.key == item.key }) { repos.append(item) }
                }
                return
            }
            guard depth < 3, let children = try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                             options: [.skipsHiddenFiles]) else { return }
            for child in children.sorted(by: { $0.path < $1.path }) where child.lastPathComponent != "node_modules" {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { visit(child, depth: depth + 1) }
            }
        }
        for root in roots { visit(URL(fileURLWithPath: expand(root), isDirectory: true), depth: 0) }
        return repos
    }

    /// The first bitbucket.org remote in a `.git/config`: git@bitbucket.org:ws/repo.git or
    /// https://user@bitbucket.org/ws/repo.git.
    static func bitbucketRemote(in config: String) -> (workspace: String, repo: String)? {
        for line in config.split(separator: "\n") where line.contains("bitbucket.org") && line.contains("url") {
            guard let range = line.range(of: #"bitbucket\.org[:/]([^/\s]+)/([^/\s]+?)(\.git)?\s*$"#, options: .regularExpression) else { continue }
            let parts = line[range].dropFirst("bitbucket.org".count + 1).split(separator: "/")
            guard parts.count == 2 else { continue }
            var repo = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            return (String(parts[0]), repo)
        }
        return nil
    }

    // MARK: Migration

    /// Earlier builds kept the repositories in `bitbucket-repos.json` and the EAS project in
    /// `eas/app.json`: the first read without a builds.json writes one from them, once. The old
    /// files are left as they are. Called under the cache's lock.
    private static func migrateIfNeeded() {
        guard ProcessInfo.processInfo.environment["CLAUDE_NOTCH_BUILDS_CONFIG"] == nil else { return }
        let notch = home.appendingPathComponent(".claude/notch")
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: notch.appendingPathComponent("eas/app.json")),
           let expo = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["expo"] as? [String: Any],
           let owner = expo["owner"] as? String, let slug = expo["slug"] as? String,
           let projectId = ((expo["extra"] as? [String: Any])?["eas"] as? [String: Any])?["projectId"] as? String {
            object["eas"] = ["account": owner, "slug": slug, "projectId": projectId]
        }
        if let data = try? Data(contentsOf: notch.appendingPathComponent("bitbucket-repos.json")),
           let repos = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["repos"] as? [[String: Any]], !repos.isEmpty {
            let entries: [[String: String]] = repos.compactMap { repo in
                guard let workspace = repo["workspace"] as? String, let name = repo["repo"] as? String else { return nil }
                var entry = ["workspace": workspace, "repo": name]
                if let path = repo["path"] as? String { entry["path"] = path.replacingOccurrences(of: home.path, with: "~") }
                return entry
            }
            if !entries.isEmpty { object["bitbucket"] = ["repos": entries] }
        }
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        do {
            try data.write(to: file, options: .withoutOverwriting)
            noteBuildLog("builds: wrote \(displayPath) from the earlier settings files")
        } catch {}
    }
}
