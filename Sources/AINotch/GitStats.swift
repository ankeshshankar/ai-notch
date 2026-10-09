import Foundation

/// Lines committed to each repository per day, from `git log --numstat`, for comparing with
/// what Claude Code wrote. Lockfiles and binary files are left out: they are not written code.
final class GitStats: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai-notch.git", qos: .utility)
    private let onUpdate: @Sendable ([String: [String: LineTally]]) -> Void
    private static let skipped = ["pnpm-lock.yaml", "package-lock.json", "yarn.lock", "Podfile.lock", "Cargo.lock", "Gemfile.lock", "composer.lock"]

    init(onUpdate: @escaping @Sendable ([String: [String: LineTally]]) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Reads the last `days` of history of each repository in `repos`.
    func refresh(_ repos: [String], days: Int) {
        queue.async { [self] in
            var result: [String: [String: LineTally]] = [:]
            for repo in repos { result[repo] = log(repo, days: days) }
            onUpdate(result)
        }
    }

    private func log(_ repo: String, days: Int) -> [String: LineTally] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Author time and subject per commit: a commit rebased or cherry-picked onto another
        // branch keeps both, so each change counts once however many branches carry it.
        process.arguments = ["-C", repo, "log", "--all", "--no-merges", "--since=\(days).days", "--numstat", "--format=@%at %s"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }

        var byDay: [String: LineTally] = [:]
        var day = ""
        var seen = Set<Substring>()
        var isCopy = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("@"), let stamp = Double(line.dropFirst().prefix { $0 != " " }) {
                day = UsageScanner.day(of: stamp)
                isCopy = !seen.insert(line).inserted
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard !isCopy, fields.count == 3, let added = Int(fields[0]), let removed = Int(fields[1]), !day.isEmpty else { continue }
            let name = (String(fields[2]) as NSString).lastPathComponent
            if Self.skipped.contains(name) { continue }
            byDay[day, default: LineTally()].add(LineTally(added: added, removed: removed, files: 1))
        }
        return byDay
    }
}
