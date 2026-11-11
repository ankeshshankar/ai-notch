import Foundation

// `AINotch --prodpage-selfcheck`: the Prod page's pure parts on made-up answers: the range, the
// series (parse, min, max, change, level, sparkline buckets), the timeline (what Datadog's answers
// give, merge, order, bounds, dedupe), the local history file, the request plan, the links, and the
// range switch. No UI, no network. Exits 1 on any failure.

enum ProdPageSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--prodpage-selfcheck") else { return }
        exit(run())
    }

    static func run() -> Int32 {
        var checks = 0, failures = 0
        func expect(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1; print("FAIL \(what)") } }
        let now = 1_800_000_000.0
        func iso(_ ago: Double) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: now - ago))
        }
        func entry(_ kind: ProdTimelineEntry.Kind, _ ago: Double, _ key: String = "m:1", _ title: String = "t") -> ProdTimelineEntry {
            ProdTimelineEntry(kind: kind, at: now - ago, title: title, detail: nil, key: key)
        }

        // Ranges.
        expect(ProdRange.allCases.map(\.seconds) == [3600, 86_400, 604_800], "ranges: 1 h, 24 h, 7 d")
        expect(ProdRange.allCases.allSatisfy { $0.seconds * 1000 / Double($0.intervalMs) <= 70 }, "ranges: at most 70 points each")
        expect(ProdRange(rawValue: "bogus") == nil && ProdRange.allCases.map(\.label) == ["1 h", "24 h", "7 d"], "ranges: labels")

        // Series parse.
        func timeseries(_ times: [Int], _ values: [Any]) -> Data {
            try! JSONSerialization.data(withJSONObject: ["data": ["type": "timeseries_response", "attributes": ["series": [[:]], "times": times, "values": [values]]]])
        }
        let parsed = ProdSeriesParse.values(timeseries([3000, 1000, 2000, 4000], [0.4, 0.1, NSNull(), 0.3]), scale: 100)
        expect(parsed == [10, 40, 30], "series: sorted by time, nulls skipped, scaled (\(String(describing: parsed)))")
        expect(ProdSeriesParse.values(timeseries([], []), scale: 1) == [], "series: no numbers is empty, not an error")
        expect(ProdSeriesParse.values(Data("{\"data\":{}}".utf8), scale: 1) == nil && ProdSeriesParse.values(Data("x".utf8), scale: 1) == nil, "series: not a timeseries answer is nil")

        // Series numbers.
        var latency = ProdSeries(label: "p95", unit: "ms", amber: 300, values: [100, 120, 400, 700, 250])
        expect(latency.minimum == 100 && latency.maximum == 700 && latency.first == 100 && latency.last == 250, "series: min, max, first, last")
        expect(latency.changeText == "+150%", "series: change vs the start is a percent (\(latency.changeText ?? "nil"))")
        expect(latency.level(250) == .ok && latency.level(301) == .amber && latency.level(600) == .red && latency.level(nil) == .ok, "series: ok under the line, amber over it, red at twice")
        expect(ProdSeries(label: "x", unit: "ms", amber: nil, values: [1, 2]).level(999) == .ok, "series: no line, never amber")
        expect(ProdSeries(label: "5xx", unit: "%", amber: 1, values: [0.2, 0.5]).changeText == "+0.3 pt", "series: a percentage changes in points")
        expect(ProdSeries(label: "5xx", unit: "%", amber: 1, values: [0.5, 0.5]).changeText == "flat", "series: no change is flat")
        expect(ProdSeries(label: "x", unit: "ms", amber: nil, values: [5]).changeText == nil, "series: one point has no change")
        expect(latency.text(93) == "93ms" && latency.text(nil) == "–", "series: value text follows the unit")
        latency.values = Array(1...120).map(Double.init)
        let spark = latency.spark(buckets: 60)
        expect(spark.count == 60 && spark.first == 1.5 && spark.last == 119.5, "series: 120 points become 60 buckets of means")
        expect(ProdSeries(label: "x", unit: "", amber: nil, values: [1, 2, 3]).spark(buckets: 60) == [1, 2, 3], "series: a short series is kept as it is")

        // Monitor alert events.
        func alertEvent(_ ago: Double, title: String, monitor: Int?, status: String? = nil, tags: [String] = []) -> [String: Any] {
            var inner: [String: Any] = ["title": title]
            if let monitor { inner["monitor_id"] = monitor }
            if let status { inner["status"] = status }
            return ["id": "e\(Int(ago))\(title.count)", "attributes": ["timestamp": iso(ago), "tags": tags, "attributes": inner]]
        }
        let alertsData = try! JSONSerialization.data(withJSONObject: ["data": [
            alertEvent(600, title: "[Triggered on {host:a}] API errors", monitor: 1, status: "error"),
            alertEvent(300, title: "[Recovered] API errors", monitor: 1, status: "ok"),
            alertEvent(200, title: "[Warn] Latency", monitor: 2, status: "warn"),
            alertEvent(150, title: "[Triggered] Other team", monitor: 9, status: "error"),
            alertEvent(120, title: "[Triggered] Leads queue", monitor: 3, status: "error", tags: ["service:leads"]),
            alertEvent(100, title: "[Triggered] Staging", monitor: 1, status: "error", tags: ["env:staging"]),
            alertEvent(90, title: "Monitor edited", monitor: 1),
            alertEvent(80, title: "[Triggered] no monitor id", monitor: nil, status: "error"),
        ]])
        let alerts = ProdTimelineEntry.alerts(alertsData, hidden: ["leads*"], monitorIds: [1, 2, 3])!
        expect(alerts.map(\.kind) == [.alert, .recovered, .warn], "alerts: triggered, recovered, warn; the rest left out (\(alerts.map(\.kind)))")
        expect(alerts.map(\.title) == ["API errors", "API errors", "Latency"], "alerts: titles lose their [..] lead")
        expect(alerts.allSatisfy { $0.key.hasPrefix("m:") }, "alerts: keyed by monitor")
        expect(ProdTimelineEntry.alerts(alertsData, hidden: [], monitorIds: nil)?.contains { $0.key == "m:9" } == true, "alerts: with no complete monitor list, other monitors stay")
        expect(ProdTimelineEntry.alerts(Data("{}".utf8), hidden: [], monitorIds: nil) == nil, "alerts: an answer with no list is nil")

        // Watchdog stories and deploys.
        func event(_ id: String, _ ago: Double, title: String, tags: [String]) -> [String: Any] {
            ["id": id, "attributes": ["timestamp": iso(ago), "tags": tags, "attributes": ["title": title]]]
        }
        let eventsData = try! JSONSerialization.data(withJSONObject: ["data": [
            event("w1", 500, title: "New error logs were detected on orders", tags: ["source:watchdog", "story_status:ongoing", "service:orders", "env:production"]),
            event("w2", 400, title: "New error logs were detected on leads", tags: ["source:watchdog", "service:leads"]),
            event("d1", 300, title: "New APM Deployment Version: 1.4.2", tags: ["source:change_tracking", "service:orders", "version:1.4.2", "previous_version:1.4.1", "env:production"]),
            event("d2", 250, title: "New APM Deployment Version: 9", tags: ["source:change_tracking", "service:orders", "version:9", "env:staging"]),
        ]])
        let stories = ProdTimelineEntry.stories(eventsData, hidden: ["leads*"])!
        expect(stories.map(\.kind) == [.watchdog, .deploy], "stories: a Watchdog story and a deploy; hidden service and other env left out (\(stories.map(\.kind)))")
        expect(stories.last?.title == "orders 1.4.2" && stories.last?.detail == "from 1.4.1" && stories.last?.key == "d:orders:1.4.2", "stories: the deploy reads service version and the previous one")

        // Incidents.
        let incidentList: [[String: Any]] = [
            ["data": ["id": "i-1", "attributes": ["title": "Checkout down", "severity": "SEV-2", "public_id": 42, "created": iso(7200), "resolved": iso(3600)]]],
            ["data": ["id": "i-2", "attributes": ["title": "Open one", "severity": "UNKNOWN", "created": iso(60)]]],
            ["data": ["id": "i-3", "attributes": ["title": "Leads outage", "created": iso(60)]]],
        ]
        let incidents = ProdTimelineEntry.incidents(incidentList, hidden: ["leads*"])
        expect(incidents.map(\.kind) == [.incidentOpened, .incidentResolved, .incidentOpened], "incidents: opened and resolved are two entries; a hidden service's is left out")
        expect(incidents.first?.title == "SEV-2 · #42 Checkout down" && incidents.last?.title == "Open one", "incidents: severity and number lead the title")

        // Triggers of the monitors that are not OK.
        var monitor = ProdMonitor(id: 7, name: "Disk", status: "Alert")
        monitor.triggeredAt = now - 100
        var okMonitor = ProdMonitor(id: 8, name: "Fine", status: "OK")
        okMonitor.triggeredAt = now - 50
        expect(ProdTimelineEntry.triggers([monitor, okMonitor]).map(\.key) == ["m:7"], "triggers: only a monitor that is not OK")

        // Merge: order, range, bounds, dedupe.
        let mixed = [entry(.alert, 100, "m:1"), entry(.recovered, 50, "m:1"), entry(.deploy, 7200, "d:a:1"), entry(.alert, 90_000, "m:2"), entry(.alert, -3600, "m:3")]
        let hour = ProdTimeline.merge(remote: mixed, local: [], now: now, range: .hour)
        expect(hour.map(\.key) == ["m:1", "m:1"] && hour.map(\.kind) == [.recovered, .alert], "merge 1 h: newest first, nothing older or from the future")
        expect(ProdTimeline.merge(remote: mixed, local: [], now: now, range: .day).count == 3, "merge 24 h: three entries")
        expect(ProdTimeline.merge(remote: mixed, local: [], now: now, range: .week).count == 4, "merge 7 d: four entries")
        let tie = ProdTimeline.merge(remote: [entry(.alert, 10, "m:2"), entry(.alert, 10, "m:1")], local: [], now: now, range: .hour)
        expect(tie == ProdTimeline.merge(remote: [entry(.alert, 10, "m:1"), entry(.alert, 10, "m:2")], local: [], now: now, range: .hour), "merge: a tie never shuffles")
        let local = [entry(.alert, 120, "m:1", "seen here"), entry(.alert, 5000, "m:1", "an hour ago"), entry(.recovered, 40, "m:4")]
        let both = ProdTimeline.merge(remote: [entry(.alert, 100, "m:1", "from datadog")], local: local, now: now, range: .day)
        expect(both.filter { $0.sameThing == "alert|m:1" }.count == 2 && both.contains { $0.title == "from datadog" } && !both.contains { $0.title == "seen here" },
               "merge: Datadog's entry wins over the same sighting within 5 minutes; a later one stays")
        expect(both.contains { $0.key == "m:4" }, "merge: the app's own entries fill in")
        let many = (0..<250).map { entry(.alert, Double($0 + 1), "m:\($0)") }
        expect(ProdTimeline.merge(remote: many, local: [], now: now, range: .day).count == ProdTimeline.showMost, "merge: at most \(ProdTimeline.showMost) listed")

        // The local history: bounded to 7 days and 300 entries.
        let old = entry(.alert, 8 * 86_400, "m:old")
        let big = (0..<400).map { entry(.alert, Double($0 * 400), "m:\($0)") }
        let bounded = ProdTimeline.bounded(big + [old], now: now)
        expect(bounded.count == ProdTimeline.keepMost && !bounded.contains { $0.key == "m:old" } && bounded.first?.key == "m:0", "history: 300 newest, nothing older than a week")
        expect(ProdTimeline.bounded([entry(.alert, 10)], adding: entry(.alert, 12), now: now).count == 1, "history: the same sighting twice is one")
        expect(ProdTimeline.bounded([entry(.alert, 10)], adding: entry(.alert, 1000), now: now).count == 2, "history: a later one is kept")

        // The history file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prod-history-check-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        ProdHistoryFile.save(bounded, to: file)
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        expect((attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file: only the user can read it")
        expect(ProdHistoryFile.load(file, now: now) == bounded, "history file: written and read back")
        expect(ProdHistoryFile.load(file, now: now + 8 * 86_400).isEmpty, "history file: a week on, it is empty")
        try? Data("not json".utf8).write(to: file)
        expect(ProdHistoryFile.load(file, now: now).isEmpty && ProdHistoryFile.load(nil, now: now).isEmpty, "history file: damaged or absent reads as empty")

        // The request plan.
        expect(ProdPagePlan.perHourOpen(numbers: 2, range: .day) == 120 + 30, "plan: 2 numbers on 24 h is 150 requests an hour")
        expect(ProdPagePlan.perHourOpen(numbers: 2, range: .week) == 120 + 30 + 12, "plan: 7 d adds the 5-minute events request")
        expect(ProdPagePlan.perHourOpen(numbers: 3, range: .week) <= ProdPagePlan.hourlyCap, "plan: three numbers on 7 d stay inside the page cap")

        // Links.
        let site = "datadoghq.com"
        func opens(_ e: ProdTimelineEntry) -> Bool { e.url(site: site, query: "tag:x").map { SafeLink.allows($0, for: .datadog) } ?? false }
        expect(opens(entry(.alert, 1, "m:12")) && opens(entry(.incidentOpened, 1, "i:abc")) && opens(entry(.deploy, 1, "d:orders:1.4.2"))
               && opens(entry(.watchdog, 1, "w:story-1")), "links: every entry kind opens a Datadog page the link check allows")
        expect(entry(.alert, 1, "m:12").url(site: site, query: "")?.absoluteString.contains("12") == true, "links: a monitor entry names its monitor")
        expect(entry(.deploy, 1, "d:../x:1").url(site: site, query: "") == nil || opens(entry(.deploy, 1, "d:../x:1")), "links: a service name cannot walk the path")
        expect(entry(.alert, 1, "zz:1").url(site: site, query: "") == nil, "links: an unknown key has no link")

        // Time text.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        expect(ProdTimeline.timeText(now - 60, now: now, calendar: calendar).count == 5, "time: today is HH:mm")
        expect(ProdTimeline.timeText(now - 2 * 86_400, now: now, calendar: calendar).count == 9, "time: another day adds the weekday")

        // The page's model: range switch, visibility, local history.
        MainActor.assumeIsolated {
            let saved = UserDefaults.standard.string(forKey: "prod.range")
            defer { if let saved { UserDefaults.standard.set(saved, forKey: "prod.range") } else { UserDefaults.standard.removeObject(forKey: "prod.range") } }
            let model = ProdPageModel(file: nil, range: .day, now: now)
            var told: [String] = []
            model.onVisibility = { open, range in told.append("\(open)/\(range.rawValue)") }
            model.setRange(.week)
            expect(model.range == .week && told == ["false/week"] && ProdRange.saved() == .week, "model: the range switch is remembered and told to the source")
            model.setRange(.week)
            expect(told.count == 1, "model: the same range again tells nothing")
            model.setOpen(true); model.setOpen(true)
            expect(told == ["false/week", "true/week"], "model: opening once tells once")
            model.setRange(.hour)
            expect(told.last == "true/hour", "model: a switch while open tells the source to read the new range")
            model.setOpen(false)
            expect(told.last == "false/hour", "model: closing tells the source to stop")
            model.record(entry(.alert, 10, "m:1"), now: now)
            model.record(entry(.alert, 11, "m:1"), now: now)
            expect(model.local.count == 1, "model: the app's own sightings are kept, once")
            expect(model.timeline(now: now, current: []).count == 1, "model: the timeline shows the history with no Datadog data")
            var data = ProdPageData()
            data.range = .hour
            data.remote = [entry(.deploy, 20, "d:a:1")]
            model.take(data)
            expect(model.timeline(now: now, current: []).count == 2, "model: Datadog's data joins the history")
        }

        print("prodpage selfcheck: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
