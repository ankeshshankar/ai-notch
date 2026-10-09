import AppKit
import ApplicationServices
import NotchCore

/// Brings a session's app to the front, and its window too when Accessibility allows it.
enum Jump {
    private static let askedKey = "askedForAccessibility"

    @MainActor
    static func to(_ session: SessionState) {
        guard let bundleId = session.appBundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return }
        // Since macOS 14 an app that is not frontmost cannot activate another one itself;
        // asking Launch Services to open the app is the route that still brings it forward.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let names = windowNames(for: session)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            guard let pid = app?.processIdentifier else { return }
            DispatchQueue.main.async { raiseWindow(of: pid, titledAny: names) }
        }
    }

    /// What the session's window title may say: its folder, or the name of a VS Code / Cursor
    /// workspace file that lists that folder ("Shop (Workspace)" for a `shop.code-workspace`).
    private static func windowNames(for session: SessionState) -> [String] {
        var names = [session.project]
        let code = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code")
        let roots = [code] + ((try? FileManager.default.contentsOfDirectory(at: code, includingPropertiesForKeys: nil)) ?? [])
        let cwd = URL(fileURLWithPath: session.cwd).standardizedFileURL.path
        for root in roots {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "code-workspace" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let folders = text.components(separatedBy: "\"path\"").dropFirst().compactMap { chunk -> String? in
                    guard let open = chunk.firstIndex(of: "\""), let close = chunk[chunk.index(after: open)...].firstIndex(of: "\"") else { return nil }
                    let path = String(chunk[chunk.index(after: open)..<close])
                    return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL.path
                }
                if folders.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) {
                    names.append(file.deletingPathExtension().lastPathComponent)
                }
            }
        }
        return names
    }

    /// Raises the app's window whose title names one of `names`.
    @MainActor
    private static func raiseWindow(of pid: pid_t, titledAny names: [String]) {
        let defaults = UserDefaults.standard
        let prompt = !defaults.bool(forKey: askedKey)
        defaults.set(true, forKey: askedKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return }

        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for name in names {
            for window in windows {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                guard let text = title as? String, text.localizedCaseInsensitiveContains(name) else { continue }
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }
}

/// An app's name and icon, from its bundle id.
@MainActor
enum AppInfo {
    private static var cache: [String: (String, NSImage)] = [:]

    static func of(_ bundleId: String?) -> (name: String, icon: NSImage)? {
        guard let bundleId else { return nil }
        if let hit = cache[bundleId] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let info = (name, NSWorkspace.shared.icon(forFile: url.path))
        cache[bundleId] = info
        return info
    }
}
