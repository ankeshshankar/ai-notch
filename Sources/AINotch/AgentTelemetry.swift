import AppKit
import Foundation
import NotchCore

/// Claude Code's own telemetry (sessions, tokens, cost, tools, how long prompts wait) sent to
/// Datadog over OTLP, for Datadog's Agent Console. Turning it on writes the exporter settings to
/// `~/.claude/settings.json` and points its `otelHeadersHelper` at `ai-notch-hook otel-headers`,
/// which prints the API key from `~/.claude/notch/datadog-otlp.key` (0600): the key is never
/// written into the settings. No prompt, code or tool input is sent (Claude Code's defaults).
enum AgentTelemetry {
    static var keyFile: URL { NotchPaths.sessions.deletingLastPathComponent().appendingPathComponent("datadog-otlp.key") }

    /// The env keys this owns in Claude Code's settings.
    private static let envKeys = ["CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER",
                                  "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
                                  "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"]

    /// On when the settings use this copy's helper, or another copy of it.
    static func isOn() -> Bool {
        guard let current = try? SettingsFile.read(SetupPaths.claudeSettings) else { return false }
        return current.json["otelHeadersHelper"]?.stringValue?.contains("ai-notch-hook") == true
    }

    /// Asks for the API key (a small window; the notch never takes typing), then writes the key
    /// file and the settings. Returns why not, if not.
    @MainActor
    static func turnOn(hook: URL) -> String? {
        guard let site = BuildsConfig.current?.datadog?.site else {
            return "Set up Prod first: the site comes from builds.json's datadog part."
        }
        let alert = NSAlert()
        alert.messageText = "Send Claude Code's telemetry to Datadog"
        alert.informativeText = "A Datadog API key (Organization Settings → API Keys) for \(site). It is kept in ~/.claude/notch/datadog-otlp.key, readable only by you, and handed to Claude Code by AI Notch's hook. Sessions you start after this send usage, cost, tool and latency metrics and events; not your prompts or code."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.placeholderString = "API key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.window.runModalAboveNotch({ alert.runModal() }) == .alertFirstButtonReturn else { return nil }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 16, key.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "That does not look like a Datadog API key." }

        do {
            let fd = open(keyFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return "The key file could not be written." }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data(key.utf8))
            try handle.close()
            _ = chmod(keyFile.path, 0o600)
            let base = "https://otlp.\(site)"
            _ = try SettingsFile.edit(SetupPaths.claudeSettings, missing: .object([])) { json in
                var out = json
                var env = out["env"] ?? .object([])
                let values: [(String, String)] = [
                    ("CLAUDE_CODE_ENABLE_TELEMETRY", "1"),
                    ("OTEL_METRICS_EXPORTER", "otlp"),
                    ("OTEL_LOGS_EXPORTER", "otlp"),
                    ("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", "http/protobuf"),
                    ("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "\(base)/v1/metrics"),
                    ("OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", "http/protobuf"),
                    ("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "\(base)/v1/logs"),
                ]
                for (name, value) in values { env[name] = .string(value) }
                out["env"] = env
                out["otelHeadersHelper"] = .string("\(Shell.quoteIfNeeded(hook.path)) otel-headers")
                return out
            }
        } catch {
            return "Claude Code's settings could not be changed: \(error)"
        }
        return nil
    }

    /// Takes the settings back out and removes the key file.
    static func turnOff() -> String? {
        do {
            _ = try SettingsFile.edit(SetupPaths.claudeSettings, missing: nil) { json in
                var out = json
                if out["otelHeadersHelper"]?.stringValue?.contains("ai-notch-hook") == true { out["otelHeadersHelper"] = nil }
                if var env = out["env"] {
                    for name in envKeys { env[name] = nil }
                    out["env"] = (env.members ?? []).isEmpty ? nil : env
                }
                return out
            }
        } catch {
            return "Claude Code's settings could not be changed: \(error)"
        }
        try? FileManager.default.removeItem(at: keyFile)
        return nil
    }
}
