import Foundation

/// Words the speech engine and the clean-up should spell right: developer jargon, the user's own
/// list, and hints about what is in front (the app, the repo and branch of a Claude session).
/// Names only, never what is on screen.
public enum DictationVocabulary {
    public static let builtIn: [String] = [
        "PR", "pull request", "Bitbucket", "GitHub", "Expo", "EAS", "Figma", "Forge", "homes", "worktree", "commit", "pipeline",
        "Datadog", "PostHog", "Linear", "TypeScript", "JavaScript", "React Native", "Next.js", "Node", "npm", "pnpm", "Swift", "SwiftUI",
        "Xcode", "Claude", "Claude Code", "Cursor", "Anthropic", "Haiku", "Sonnet", "Opus", "API", "SDK", "OTA", "TestFlight",
        "Kubernetes", "Docker", "Redis", "MongoDB", "Postgres", "GraphQL", "webhook", "endpoint", "middleware", "refactor",
        "merge", "rebase", "branch", "staging", "prod", "localhost", "JSON", "YAML", "CLI", "CI", "linter", "tsc", "ESLint",
        "Jest", "Metabase", "Sentry", "Vercel", "AWS", "Firebase", "OAuth", "JWT", "WebSocket",
    ]

    /// The most terms handed to the engine or the prompt: more dilutes the hints.
    public static let limit = 120

    /// One term per line or comma; blanks and over-long lines dropped.
    public static func parse(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 40 }
    }

    /// Dynamic hints first (most specific), then the user's terms, then the built-in list; duplicates
    /// (case-insensitive) dropped, capped at `limit`.
    public static func merged(dynamic: [String] = [], user: [String] = [], builtIn: [String] = DictationVocabulary.builtIn) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in dynamic + user + builtIn {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            out.append(clean)
            if out.count >= limit { break }
        }
        return out
    }

    /// Words of a repo or branch name worth hinting: `feat/dictation-quality` gives the whole name
    /// and its parts; short noise (`feat`, `fix`) is dropped.
    public static func hints(fromName name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "HEAD" else { return [] }
        let noise: Set<String> = ["feat", "fix", "chore", "docs", "refactor", "test", "main", "master", "wip"]
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: "/-_. "))
            .filter { $0.count >= 4 && !noise.contains($0.lowercased()) }
        return [trimmed] + parts
    }
}
