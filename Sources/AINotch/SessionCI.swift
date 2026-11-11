import Foundation

// The latest CI run for a session's branch, matched from what Pipelines and EAS already fetched:
// no request of its own. A Bitbucket run names its repository and branch (and its commit); an EAS
// build names only the commit, so it matches the session's HEAD.

/// One mark on a session's row: how the latest run on its branch stands, and what it was.
struct CIMark: Equatable {
    enum State: String, Equatable { case running, passed, failed }
    enum Source: Equatable { case pipelines, eas }

    var state: State
    var source: Source
    /// "Pipeline #42 · custom: eas-preview", "EAS ios build · preview".
    var name: String
    /// When it was created (which run is the latest), and when it finished or else began (its age).
    var created: Double
    var at: Double
    var url: URL

    var word: String {
        switch state {
        case .running: return "running"
        case .passed: return "passed"
        case .failed: return "failed"
        }
    }
}

enum SessionCI {
    /// The newest run that is not canceled: a Bitbucket run of the session's repository on its
    /// branch (or on its commit), or an EAS build of its HEAD commit. Nil when none matches.
    static func match(_ git: SessionGit, runs: [PipelineRun], builds: [EASBuild]) -> CIMark? {
        guard git.isRepo else { return nil }
        var found: [CIMark] = []
        if let repo = git.repo?.lowercased() {
            for run in runs where run.ref.workspace.lowercased() + "/" + run.ref.repo.lowercased() == repo {
                let onBranch = git.branch != nil && run.branch == git.branch
                guard onBranch || sameCommit(run.commit, git.head), let state = state(run.state) else { continue }
                let selector = run.selector.map { " · \($0)" } ?? ""
                found.append(CIMark(state: state, source: .pipelines, name: "Pipeline #\(run.ref.number)\(selector)",
                                    created: run.createdAt, at: run.completedAt ?? run.createdAt, url: run.url))
            }
        }
        for build in builds where sameCommit(build.commit, git.head) {
            guard let state = state(build.state) else { continue }
            found.append(CIMark(state: state, source: .eas, name: "EAS \(build.platform) build" + (build.profile.map { " · \($0)" } ?? ""),
                                created: build.createdAt, at: build.completedAt ?? build.createdAt, url: build.url))
        }
        return found.max { $0.created < $1.created }
    }

    /// Queued, running and paused (at a manual step) read as running; a canceled run says nothing.
    static func state(_ state: BuildState) -> CIMark.State? {
        switch state {
        case .queued, .running, .paused: return .running
        case .succeeded: return .passed
        case .failed: return .failed
        case .canceled: return nil
        }
    }

    /// The same commit, whether one side is a short hash (at least 7 characters).
    static func sameCommit(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased(), a.count >= 7, b.count >= 7 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }
}
