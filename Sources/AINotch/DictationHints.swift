import AppKit
import DictationCore
import Foundation
import NotchCore

/// What dictation tells the speech engine and the clean-up to spell right: the built-in jargon, the
/// user's own list, the front app, and, when a terminal or editor is in front, the repo and branch
/// of the Claude session worked in most recently. Names only; nothing is read from the screen.
enum DictationHints {
    /// The words to hint now, most specific first.
    static func vocabulary(frontApp: String?, bundleID: String?, user: [String]) -> [String] {
        var dynamic: [String] = []
        if let app = frontApp, !app.isEmpty { dynamic.append(app) }
        let context = AppContext.of(appName: frontApp, bundleID: bundleID)
        if context == .terminal || context == .editor, let work = recentSessionWork() {
            dynamic.append(work.repo)
            dynamic += work.branch.map(DictationVocabulary.hints(fromName:)) ?? []
        }
        return DictationVocabulary.merged(dynamic: dynamic, user: user)
    }

    /// The repo folder and git branch of the Claude session updated last within six hours.
    static func recentSessionWork() -> (repo: String, branch: String?)? {
        let dir = NotchPaths.sessions
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let cutoff = Date().timeIntervalSince1970 - 6 * 3600
        var best: SessionState?
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder.notch.decode(SessionState.self, from: data),
                  state.updatedAt > cutoff, state.updatedAt > (best?.updatedAt ?? 0) else { continue }
            best = state
        }
        guard let state = best else { return nil }
        let folder = state.workDir ?? state.cwd
        return (URL(fileURLWithPath: folder).lastPathComponent, branch(in: folder))
    }

    /// The checked-out branch, read from `.git/HEAD` (also in a linked worktree, where `.git` is a file).
    static func branch(in folder: String) -> String? {
        let fm = FileManager.default
        var git = folder + "/.git"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: git, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOfFile: git, encoding: .utf8), pointer.hasPrefix("gitdir:") else { return nil }
            git = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            if !git.hasPrefix("/") { git = folder + "/" + git }
        }
        guard let head = try? String(contentsOfFile: git + "/HEAD", encoding: .utf8) else { return nil }
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : nil
    }
}
