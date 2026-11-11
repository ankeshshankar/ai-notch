import Foundation

/// Where a session really works. A session starts in one folder, but its agent often edits
/// in another checkout of the same repository (a linked git worktree). This reads that from
/// the file system alone (no git process: the hook must stay fast) and finds the folders a
/// shell command names.
public enum WorkTree {
    public struct Info: Equatable, Sendable {
        /// The checkout's top-level folder (symlinks resolved).
        public var root: String
        /// The repository's shared git folder: equal for every checkout of one repository.
        public var common: String
        /// A linked worktree, not the main checkout.
        public var isLinked: Bool
        public var name: String { (root as NSString).lastPathComponent }
    }

    /// `path` with symlinks resolved by realpath(3) on its longest existing part (so a file that
    /// does not exist yet, or a /var that is /private/var, always reads the same way).
    public static func real(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var rest: [String] = []
        for _ in 0..<60 {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing || parent.isEmpty { break }
            rest.append((existing as NSString).lastPathComponent)
            existing = parent
        }
        return path
    }

    /// The checkout `path` (a file or a folder, which may not exist yet) lies in: the nearest
    /// folder above it with a `.git` entry. A `.git` folder is a main checkout; a `.git` file
    /// pointing into `<repo>/.git/worktrees/<name>` is a linked worktree.
    public static func info(of path: String) -> Info? {
        guard path.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        var dir = real(path)
        for _ in 0..<60 {
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return Info(root: dir, common: real(git), isLinked: false) }
                guard let text = try? String(contentsOfFile: git, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                var target = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if !target.hasPrefix("/") { target = dir + "/" + target }
                target = real(target)
                if let range = target.range(of: "/worktrees/", options: .backwards) {
                    return Info(root: dir, common: String(target[..<range.lowerBound]), isLinked: true)
                }
                return Info(root: dir, common: target, isLinked: false)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
        return nil
    }

    /// What an acting signal at a path means for a session that started in `start`: it is the start
    /// checkout, another checkout of the same repository, or not that repository at all.
    public enum Verdict: Equatable, Sendable { case start, other(String), ignored }

    public static func verdict(for path: String, start: String) -> Verdict {
        guard let target = info(of: path), let origin = info(of: start), target.common == origin.common else { return .ignored }
        return target.root == origin.root ? .start : .other(target.root)
    }

    // MARK: Shell commands

    /// The folders a shell command names, in the order written: `git -C <path>`, `cd <path>`,
    /// `git worktree add <path>`. Relative paths are taken from `cwd`; a path with a variable
    /// other than $HOME or a substitution is skipped (it cannot be known here).
    public static func folders(inCommand command: String, cwd: String) -> [String] {
        var found: [(at: Int, path: String)] = []
        let text = command as NSString
        let arg = #"("[^"]*"|'[^']*'|[^\s;&|)<>]+)"#

        func collect(_ pattern: String, group: Int = 1, _ make: (String) -> String? = { $0 }) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: command, range: NSRange(location: 0, length: text.length)) {
                let range = match.range(at: group)
                guard range.location != NSNotFound, let path = resolve(text.substring(with: range), cwd: cwd), let made = make(path) else { continue }
                found.append((match.range.location, made))
            }
        }
        collect(#"\bgit\s+(?:[^;&|]*?\s)?-C\s+"# + arg)
        collect(#"(?:^|[;&|(]|&&)\s*cd\s+"# + arg)
        // `git worktree add [options] <path>`: -b/-B take a branch name first.
        if let regex = try? NSRegularExpression(pattern: #"\bgit\s+(?:-C\s+\S+\s+)?worktree\s+add\s+([^;&|]*)"#) {
            for match in regex.matches(in: command, range: NSRange(location: 0, length: text.length)) {
                var tokens = text.substring(with: match.range(at: 1)).split(separator: " ").map(String.init)
                while let first = tokens.first {
                    if first == "-b" || first == "-B" { tokens.removeFirst(min(2, tokens.count)) }
                    else if first.hasPrefix("-") { tokens.removeFirst() }
                    else { break }
                }
                if let first = tokens.first, let path = resolve(first, cwd: cwd) { found.append((match.range.location + 1, path)) }
            }
        }
        return found.sorted { $0.at < $1.at }.map(\.path)
    }

    /// One shell word as an absolute path, or nil when it cannot be known.
    static func resolve(_ word: String, cwd: String) -> String? {
        var text = word
        if (text.hasPrefix("\"") && text.hasSuffix("\"") || text.hasPrefix("'") && text.hasSuffix("'")), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        let home = NSHomeDirectory()
        if text == "~" || text.hasPrefix("~/") { text = home + text.dropFirst() }
        text = text.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        guard !text.isEmpty, !text.contains("$"), !text.contains("`"), !text.hasPrefix("-") else { return nil }
        let full = text.hasPrefix("/") ? text : cwd + "/" + text
        return (full as NSString).standardizingPath
    }
}
