import Foundation

/// The `permissions.ask` rules of the settings Claude Code reads for a session: what you want to
/// approve every single time (deleting, moving, pushing, deploying…). A prompt one of them covers
/// never gets "Allow for session" in the notch, whatever Claude Code suggested.
///
/// Matching follows Claude Code's own for `Bash(…)` rules: `prefix:*` is a prefix at a word
/// boundary, a `*` anywhere is a wildcard (a single trailing ` *` also matches the bare command, so
/// `git push *` covers `git push`), anything else is the exact command. Every part of a compound
/// command (`a && b | c`, `$(…)`, a subshell) is checked on its own, after leading `VAR=value`
/// assignments and wrappers (`timeout`, `nice`, `nohup`, `env`, `sudo`, `xargs`…) are taken off.
/// It errs towards a match: a rule that might cover the call counts.
public enum AskRules {
    /// The ask rules in managed, user, project and local settings for the folders the session ran in.
    public static func load(projectDirs: [String]) -> [String] {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let configDir = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        var files = ["/Library/Application Support/ClaudeCode/managed-settings.json", configDir + "/settings.json"]
        var seen = Set<String>()
        for dir in projectDirs where !dir.isEmpty && seen.insert(dir).inserted {
            files += [dir + "/.claude/settings.json", dir + "/.claude/settings.local.json"]
        }
        var rules: [String] = []
        for file in files {
            guard let data = fm.contents(atPath: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ask = (json["permissions"] as? [String: Any])?["ask"] as? [Any] else { continue }
            rules += ask.compactMap { $0 as? String }
        }
        return rules
    }

    /// The first rule that covers a call of `tool` with `input`, if any.
    public static func match(tool: String, input: [String: Any], rules: [String]) -> String? {
        for rule in rules {
            let (name, content) = parse(rule)
            if tool.hasPrefix("mcp__"), name.hasPrefix("mcp__") {
                // `mcp__server`, `mcp__server__*` or `mcp__server__tool`.
                let server = name.hasSuffix("__*") ? String(name.dropLast(3)) : name
                if tool == name || tool.hasPrefix(server + "__") { return rule }
                continue
            }
            guard name == tool else { continue }
            guard let content, !content.isEmpty, content != "*" else { return rule }
            if tool == "Bash" {
                if covers(content, command: input["command"] as? String ?? "") { return rule }
            } else {
                // Paths, domains and the rest: any rule on this tool might cover it.
                return rule
            }
        }
        return nil
    }

    /// Whether the Bash rule content `pattern` covers `command` or any part of it.
    public static func covers(_ pattern: String, command: String) -> Bool {
        let candidates = commandForms(command)
        let kind = Kind(pattern)
        return candidates.contains { kind.matches($0) }
    }

    /// `Bash(rm *)` → ("Bash", "rm *"); `WebFetch` → ("WebFetch", nil).
    static func parse(_ rule: String) -> (String, String?) {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return (trimmed, nil) }
        let name = String(trimmed[..<open])
        let content = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        return (name, content.replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")"))
    }

    private enum Kind {
        case prefix(String)
        case wildcard(NSRegularExpression?)
        case exact(String)

        init(_ pattern: String) {
            let pattern = collapse(pattern)
            if pattern.hasSuffix(":*") {
                self = .prefix(String(pattern.dropLast(2)).trimmingCharacters(in: .whitespaces))
            } else if hasWildcard(pattern) {
                self = .wildcard(regex(pattern))
            } else {
                self = .exact(pattern)
            }
        }

        func matches(_ command: String) -> Bool {
            switch self {
            case .prefix(let prefix): return command == prefix || command.hasPrefix(prefix + " ")
            // A pattern that cannot be read covers everything rather than nothing.
            case .wildcard(let regex):
                guard let regex else { return true }
                return regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
            case .exact(let exact): return command == exact
            }
        }
    }

    private static func hasWildcard(_ pattern: String) -> Bool {
        var escaped = false
        for char in pattern {
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "*" { return true }
        }
        return false
    }

    /// Claude Code's wildcard: `*` is any run of characters, `\*` a star, the rest literal, the
    /// whole command anchored; one trailing ` *` makes the arguments optional.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        var body = ""
        var stars = 0
        var chars = Array(pattern)[...]
        while let char = chars.popFirst() {
            if char == "\\", let next = chars.first, next == "*" || next == "\\" {
                chars.removeFirst()
                body += NSRegularExpression.escapedPattern(for: String(next))
            } else if char == "*" {
                stars += 1
                body += ".*"
            } else {
                body += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        if stars == 1, body.hasSuffix(" .*") { body = String(body.dropLast(3)) + "( .*)?" }
        return try? NSRegularExpression(pattern: "^" + body + "$", options: [.dotMatchesLineSeparators])
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// The command as rules see it: the whole of it, and each part on its own, without leading
    /// assignments and wrappers, with and without redirections, by name and by full path.
    static func commandForms(_ command: String) -> [String] {
        var forms: [String] = []
        var seen = Set<String>()
        func add(_ text: String) {
            let form = collapse(text.trimmingCharacters(in: .whitespacesAndNewlines))
            if !form.isEmpty, seen.insert(form).inserted { forms.append(form) }
        }
        add(command)
        for part in parts(command) {
            for stripped in unwrapped(part) {
                add(stripped)
                add(withoutRedirections(stripped))
            }
        }
        return forms
    }

    /// The simple commands in `command`: split at `;`, `&`, `|`, newlines, parentheses, braces and
    /// backticks outside single quotes, and inside `sh -c '…'` too. Over-splitting only finds more
    /// parts to check.
    static func parts(_ command: String, depth: Int = 0) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var chars = Array(command)[...]
        while let char = chars.popFirst() {
            if inSingle {
                if char == "'" { inSingle = false }
                current.append(char)
                continue
            }
            switch char {
            case "'":
                inSingle = true
                current.append(char)
            case "\\":
                current.append(char)
                if let next = chars.popFirst() { current.append(next) }
            case ";", "&", "|", "\n", "\r", "(", ")", "`", "{", "}":
                parts.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        parts.append(current)
        var result: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result.append(trimmed)
            // `bash -c "…"`: the script it runs is commands too.
            if depth < 3, let script = shellScript(trimmed) { result += Self.parts(script, depth: depth + 1) }
        }
        return result
    }

    private static func shellScript(_ part: String) -> String? {
        let words = part.split(separator: " ", maxSplits: 2).map(String.init)
        guard words.count == 3, ["sh", "bash", "zsh", "dash", "fish"].contains((words[0] as NSString).lastPathComponent),
              words[1].hasPrefix("-"), words[1].contains("c") else { return nil }
        var script = words[2].trimmingCharacters(in: .whitespaces)
        if let first = script.first, first == "'" || first == "\"", script.count >= 2, script.last == first {
            script = String(script.dropFirst().dropLast())
        }
        return script
    }

    /// Wrappers that run the command after them, and their options that take a value.
    private static let wrappers: [String: Set<String>] = [
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "time": [], "nohup": [], "command": [], "builtin": [], "exec": [], "caffeinate": [],
        "nice": ["-n", "--adjustment"],
        "stdbuf": ["-i", "-o", "-e"],
        "env": ["-u", "-C", "-S", "--unset", "--chdir"],
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-T", "-U", "--user", "--group"],
        "doas": ["-u", "-C"],
        "xargs": ["-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "-J", "-R", "-S"],
    ]

    /// The part, then the command under each wrapper, with leading `VAR=value`s taken off; and
    /// the same with a full path to the program cut to its name.
    static func unwrapped(_ part: String) -> [String] {
        var words = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)[...]
        var forms: [String] = []
        func note() {
            guard let first = words.first else { return }
            let name = (first as NSString).lastPathComponent
            forms.append(words.joined(separator: " "))
            if first.contains("/") { forms.append(([name] + words.dropFirst()).joined(separator: " ")) }
            // `git -C dir push`: git's own options before the subcommand.
            if name == "git" {
                var rest = Array(words.dropFirst())[...]
                while let word = rest.first, word.hasPrefix("-") {
                    rest.removeFirst()
                    if ["-C", "-c", "--git-dir", "--work-tree", "--namespace"].contains(word), !rest.isEmpty { rest.removeFirst() }
                }
                forms.append((["git"] + rest).joined(separator: " "))
            }
        }
        for _ in 0..<8 {
            while let first = words.first, isAssignment(first) { words.removeFirst() }
            // `! cmd`, `"cmd`: what a split left in front.
            while let first = words.first, first == "!" || first == "then" || first == "do" || first == "else" { words.removeFirst() }
            note()
            guard let first = words.first, let valued = wrappers[(first as NSString).lastPathComponent] else { break }
            words.removeFirst()
            let name = (first as NSString).lastPathComponent
            while let word = words.first {
                if word == "--" { words.removeFirst(); break }
                if word.hasPrefix("-") {
                    words.removeFirst()
                    if valued.contains(word), !words.isEmpty { words.removeFirst() }
                    continue
                }
                if name == "env", isAssignment(word) { words.removeFirst(); continue }
                if name == "timeout", word.first?.isNumber == true { words.removeFirst(); break }
                break
            }
        }
        return forms
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `cmd > out 2>&1` → `cmd`.
    private static func withoutRedirections(_ command: String) -> String {
        var words = command.split(separator: " ").map(String.init)
        var index = 0
        while index < words.count {
            let word = words[index]
            let body = word.drop(while: \.isNumber)
            if body.hasPrefix(">") || body.hasPrefix("<") || body.hasPrefix("&>") {
                let operatorOnly = body.allSatisfy { $0 == ">" || $0 == "<" || $0 == "&" || $0 == "|" }
                words.remove(at: index)
                if operatorOnly, index < words.count { words.remove(at: index) }
                continue
            }
            index += 1
        }
        return words.joined(separator: " ")
    }
}
