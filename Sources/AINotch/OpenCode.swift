import Foundation

/// OpenCode reports its sessions through a plugin Setup writes to
/// `~/.config/opencode/plugins/ai-notch.js`: on its session, tool and permission events it runs
/// `ai-notch-hook report …` (working with the tool, waiting on a permission, idle, ended), so
/// each OpenCode session is its own row, from the terminal UI, `opencode serve` or the desktop
/// app alike. The plugin only reports; it never answers or blocks anything.
enum OpenCodePlugin {
    static var configDir: URL { SetupPaths.home.appendingPathComponent(".config/opencode", isDirectory: true) }
    static var file: URL { configDir.appendingPathComponent("plugins/ai-notch.js") }

    /// OpenCode is installed or has run: its config or data folder, or its program where installers put it.
    static var hasOpenCode: Bool {
        let home = SetupPaths.home.path
        let dirs = [configDir.path, "\(home)/.local/share/opencode", "\(home)/.opencode"]
        let programs = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "\(home)/.opencode/bin/opencode",
                        "/Applications/OpenCode.app"]
        return dirs.contains { FileManager.default.fileExists(atPath: $0) } || programs.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// The plugin, pointed at this copy's hook.
    static func source(hook: String) -> String {
        let quoted = String(data: (try? JSONSerialization.data(withJSONObject: [hook], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8), encoding: .utf8)!
        return """
        // AI Notch: shows OpenCode's sessions in the notch. Written by AI Notch's Setup; Disconnect
        // removes it. It only reports (ai-notch-hook report); it never answers or blocks anything.
        const [HOOK] = \(quoted);

        export const AINotch = async ({ $, directory }) => {
          const titles = new Map();
          const send = (phase, id, detail) => {
            if (!id) return;
            const args = ["report", phase, "--agent", "OpenCode", "--id", "opencode-" + id, "--cwd", directory, "--pid", String(process.pid)];
            const title = titles.get(id);
            if (title) args.push("--title", title);
            if (detail) args.push("--detail", String(detail).slice(0, 120));
            $`${HOOK} ${args}`.quiet().nothrow().catch(() => {});
          };
          return {
            event: async ({ event }) => {
              const p = event.properties ?? {};
              const id = p.sessionID ?? p.info?.id;
              switch (event.type) {
                case "session.created":
                case "session.updated":
                  if (p.info?.title) titles.set(p.info.id, p.info.title);
                  if (event.type === "session.created") send("idle", id);
                  break;
                case "session.status":
                  send(p.status?.type === "idle" ? "idle" : "working", id);
                  break;
                case "session.idle":
                  send("idle", id);
                  break;
                case "permission.asked":
                case "permission.updated":
                  send("waiting", id, "permission: " + (p.permission ?? p.type ?? p.title ?? "a tool"));
                  break;
                case "permission.replied":
                  send("working", id);
                  break;
                case "session.error":
                  send("idle", id);
                  break;
                case "session.deleted":
                  send("end", id);
                  titles.delete(id);
                  break;
              }
            },
            "tool.execute.before": async (input) => {
              send("working", input?.sessionID, input?.tool);
            },
          };
        };

        """
    }

    static func status(hook: String) -> ItemStatus {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .notSetUp }
        if text == source(hook: hook) { return .done }
        if let range = text.range(of: #"const \[HOOK\] = \["([^"]*)"\]"#, options: .regularExpression) {
            let path = String(text[range]).components(separatedBy: "\"").dropFirst().first ?? ""
            if !path.isEmpty, path != hook { return .otherCopy(path) }
        }
        return .incomplete
    }

    static func install(hook: String) throws -> SettingsFile.Written? {
        let text = source(hook: hook)
        if (try? String(contentsOf: file, encoding: .utf8)) == text { return nil }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        return SettingsFile.Written(file: file, backup: nil)
    }

    /// Only AI Notch's own plugin file.
    static func remove() throws -> SettingsFile.Written? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("// AI Notch:") else { return nil }
        try FileManager.default.removeItem(at: file)
        return SettingsFile.Written(file: file, backup: nil)
    }
}
