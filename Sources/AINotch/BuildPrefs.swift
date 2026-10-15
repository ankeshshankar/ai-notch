import AppKit
import CoreImage
import Foundation

/// What the Pipelines section shows, remembered across restarts: Mine or All, muted
/// repositories, pinned runs and a branch filter.
struct PipelinePrefs: Equatable {
    enum Scope: String { case mine, all }

    var scope: Scope = .mine
    /// "ws/repo" for a Bitbucket repository, "eas" for EAS builds.
    var muted: Set<String> = []
    /// Row ids that always show until unpinned.
    var pinned: [String] = []
    var branch: String?

    private static let key = "pipelines.prefs"

    static func load() -> PipelinePrefs {
        let defaults = UserDefaults.standard
        var prefs = PipelinePrefs()
        guard let object = defaults.dictionary(forKey: key) else { return prefs }
        prefs.scope = Scope(rawValue: object["scope"] as? String ?? "") ?? .mine
        prefs.muted = Set(object["muted"] as? [String] ?? [])
        prefs.pinned = object["pinned"] as? [String] ?? []
        prefs.branch = (object["branch"] as? String)?.nonEmpty
        return prefs
    }

    func save() {
        UserDefaults.standard.set(["scope": scope.rawValue, "muted": muted.sorted(), "pinned": pinned, "branch": branch ?? ""], forKey: Self.key)
    }
}

/// The public status pages of EAS and Bitbucket, every 10 minutes: nil while operational, else a
/// few words and the page's own description.
struct ServiceHealth: Equatable, Sendable {
    var eas: String?
    var easDetail: String?
    var bitbucket: String?
    var bitbucketDetail: String?
}

final class ServiceStatusPoller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai-notch.status", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var last = ServiceHealth()
    private let onChange: @Sendable (ServiceHealth) -> Void

    static let every: Double = 600

    init(onChange: @escaping @Sendable (ServiceHealth) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: Self.every, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    private func poll() {
        if BuildPolling.isScreenLocked { return }
        var next = last
        // EAS: the "EAS Build" component of Expo's page.
        if let object = fetch("https://status.expo.dev/api/v2/summary.json"),
           let components = object["components"] as? [[String: Any]] {
            let build = components.first { ($0["name"] as? String) == "EAS Build" }
            let state = build?["status"] as? String ?? "operational"
            next.eas = state == "operational" ? nil : Self.words(state)
            let incident = (object["incidents"] as? [[String: Any]])?.first?["name"] as? String
            next.easDetail = state == "operational" ? nil : "EAS Build: \(state.replacingOccurrences(of: "_", with: " "))\(incident.map { ". \($0)" } ?? "")"
        }
        // Bitbucket: the page's overall indicator.
        if let object = fetch("https://bitbucket.status.atlassian.com/api/v2/status.json"),
           let status = object["status"] as? [String: Any] {
            let indicator = status["indicator"] as? String ?? "none"
            next.bitbucket = indicator == "none" ? nil : (indicator == "minor" ? "degraded" : indicator == "major" ? "outage" : indicator)
            next.bitbucketDetail = indicator == "none" ? nil : status["description"] as? String
        }
        if next != last {
            last = next
            onChange(next)
        }
    }

    private static func words(_ state: String) -> String {
        switch state {
        case "degraded_performance": return "degraded"
        case "partial_outage": return "partial outage"
        case "major_outage": return "outage"
        case "under_maintenance": return "maintenance"
        default: return state.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func fetch(_ string: String) -> [String: Any]? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = EASGraphQL.syncData(request), response.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// A QR code for a URL, sharp at any size.
enum QRCode {
    static func image(for url: URL, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (size * 2 / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}
