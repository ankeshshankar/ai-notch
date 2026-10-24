import Foundation

// `AINotch --deploy-check-selfcheck`: the deploy checks, new errors, deploys list, Watchdog, the
// `services` and `hiddenServices` config, the 20-minute window and the hourly budget, on made-up
// answers in Datadog's shapes. No network. Exits 1 on any failure. Neutral names only.

enum DeployCheckSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--deploy-check-selfcheck") else { return }
        exit(run())
    }

    /// A timeseries answer: for each (version, env) the hits, the error rate and the p95 (seconds)
    /// in the buckets from `from` to `to`, null outside; three series each, in query order.
    static func timeseries(_ specs: [(version: String, env: String, from: Double, to: Double, hits: Double, errorRate: Double, p95: Double)],
                           from: Double, to: Double, interval: Double = 300) -> Data {
        var times: [Double] = []
        var t = from
        while t <= to { times.append(t); t += interval }
        var series: [[String: Any]] = []
        var values: [[Any]] = []
        for spec in specs {
            let tags = ["env:\(spec.env)", "version:\(spec.version)"]
            func column(_ value: (Double) -> Double) -> [Any] { times.map { $0 >= spec.from && $0 < spec.to ? value($0) as Any : NSNull() } }
            series.append(["group_tags": tags, "query_index": 0]); values.append(column { _ in spec.hits })
            series.append(["group_tags": tags, "query_index": 1]); values.append(column { _ in spec.hits * spec.errorRate })
            series.append(["group_tags": tags, "query_index": 2]); values.append(column { _ in spec.p95 })
        }
        let body: [String: Any] = ["data": ["type": "timeseries_response", "attributes": [
            "series": series, "times": times.map { $0 * 1000 }, "values": values]]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ condition: Bool, _ what: String) {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL \(what)")
            }
        }
        // Buckets are 5 minutes; `now` sits on a boundary.
        let now: Double = 1_000_200
        let day = now - 86400

        // 1. The verdict, from a service whose version changed 15 minutes ago.
        func verdict(old: (rate: Double, p95: Double, hits: Double), new: (rate: Double, p95: Double, hits: Double)) -> DeployVerdict? {
            let data = timeseries([("1.4.1", "prod", day, now - 900, old.hits, old.rate, old.p95),
                                   ("1.4.2", "prod", now - 900, now, new.hits, new.rate, new.p95)], from: day, to: now - 300)
            guard let merged = DeployAnalysis.parse(data) else { return nil }
            let analysis = DeployAnalysis.analyze(merged, now: now, interval: 300)
            guard let version = analysis.current, let stats = analysis.new else { return nil }
            return DeployVerdict.make(version: version, previous: analysis.previous, new: stats, old: analysis.old)
        }
        let worse = verdict(old: (0.004, 0.18, 600), new: (0.021, 0.21, 590))
        expect(worse?.state == .worse, "worse: state \(String(describing: worse?.state))")
        expect(worse?.line == "v1.4.2 vs v1.4.1: errors 0.4→2.1% ▲ · p95 180→210ms ▲ · 120→118/min",
               "worse: line \(worse?.line ?? "nil")")
        let better = verdict(old: (0.03, 0.30, 600), new: (0.004, 0.18, 600))
        expect(better?.state == .better && better?.errors == .down && better?.latency == .down, "better: \(String(describing: better?.state)) \(better?.line ?? "")")
        let same = verdict(old: (0.004, 0.18, 600), new: (0.0045, 0.185, 590))
        expect(same?.state == .same && same?.errors == .flat && same?.latency == .flat && same?.traffic == .flat, "same: \(String(describing: same?.state)) \(same?.line ?? "")")
        let dropped = verdict(old: (0.004, 0.18, 600), new: (0.004, 0.18, 150))
        expect(dropped?.state == .worse && dropped?.traffic == .down, "traffic down to a quarter is worse: \(String(describing: dropped?.state))")
        expect(dropped?.line.hasSuffix("120→30/min ▼") == true, "traffic line: \(dropped?.line ?? "")")
        // A slower p95 in seconds is told in seconds.
        let slow = verdict(old: (0.004, 0.9, 600), new: (0.004, 1.4, 600))
        expect(slow?.state == .worse && slow?.line.contains("p95 0.9→1.4s ▲") == true, "p95 in seconds: \(slow?.line ?? "")")
        // Too few requests on the new version: no verdict yet.
        let early = verdict(old: (0.004, 0.18, 600), new: (0.5, 0.5, 3))
        expect(early?.state == .collecting, "collecting: \(String(describing: early?.state))")
        // No previous version in the day: the new one's numbers alone.
        let single = timeseries([("1.4.2", "prod", day, now, 600, 0.004, 0.18)], from: day, to: now - 300)
        let singleAnalysis = DeployAnalysis.analyze(DeployAnalysis.parse(single) ?? [:], now: now, interval: 300)
        let alone = singleAnalysis.new.flatMap { DeployVerdict.make(version: "1.4.2", previous: singleAnalysis.previous, new: $0, old: singleAnalysis.old) }
        expect(alone?.state == .noPrevious && singleAnalysis.deploys.isEmpty && singleAnalysis.previous == nil, "no previous version: \(String(describing: alone?.state))")
        expect(alone?.line.contains("nothing earlier to compare") == true, "no previous line: \(alone?.line ?? "")")

        // 2. prod and production are one environment; another env is left out.
        let merged1 = DeployAnalysis.parse(timeseries([("1.4.1", "prod", day, now - 900, 600, 0.004, 0.18), ("1.4.2", "prod", now - 900, now, 590, 0.021, 0.21)],
                                                     from: day, to: now - 300))
        let merged2 = DeployAnalysis.parse(timeseries([("1.4.1", "prod", day, now - 900, 300, 0.004, 0.18), ("1.4.1", "production", day, now - 900, 300, 0.004, 0.18),
                                                      ("1.4.2", "production", now - 900, now, 590, 0.021, 0.21), ("1.4.2", "staging", now - 900, now, 9000, 0.5, 2),
                                                      ("1.5.0-rc", "staging", now - 900, now, 9000, 0.5, 2)],
                                                     from: day, to: now - 300))
        expect(merged2?.keys.sorted() == ["1.4.1", "1.4.2"], "staging left out: \(merged2?.keys.sorted() ?? [])")
        let a1 = DeployAnalysis.analyze(merged1 ?? [:], now: now, interval: 300), a2 = DeployAnalysis.analyze(merged2 ?? [:], now: now, interval: 300)
        expect(a1.new == a2.new && a1.old == a2.old && a1.new != nil, "prod + production = prod: \(String(describing: a1.old)) vs \(String(describing: a2.old))")
        expect(DeployEnv.isProd("Production") && DeployEnv.isProd("prod") && !DeployEnv.isProd("staging") && !DeployEnv.isProd("preprod"), "isProd")

        // 3. The deploys list: the busiest version changing; a one-bucket straggler is not a deploy; a rollback is.
        let feed = DeployAnalysis.analyze(DeployAnalysis.parse(timeseries([
            ("1.4.0", "prod", day, now - 36000, 600, 0.004, 0.18),
            ("1.4.1", "prod", now - 36000, now - 9000, 600, 0.004, 0.18),
            ("1.4.0", "prod", now - 12000, now - 11700, 700, 0.004, 0.18),   // one stray bucket
            ("1.4.2", "prod", now - 9000, now - 900, 600, 0.004, 0.18),
            ("1.4.1", "prod", now - 900, now, 600, 0.004, 0.18),             // rolled back
        ], from: day, to: now - 300)) ?? [:], now: now, interval: 300)
        expect(feed.deploys.map(\.version) == ["1.4.1", "1.4.2", "1.4.1"], "deploys, newest first: \(feed.deploys.map(\.version))")
        expect(feed.deploys.first.map { $0.previous == "1.4.2" && $0.at == now - 900 } == true, "rollback is a deploy: \(String(describing: feed.deploys.first))")
        expect(feed.current == "1.4.1" && feed.previous == "1.4.2", "current and previous: \(String(describing: feed.current)) \(String(describing: feed.previous))")
        let entry = DeployEntry(version: "1.4.2", previous: "1.4.1", at: now - 720)
        expect(DeployReport(service: "orders", at: now).deployLine(entry, now: now) == "v1.4.2 · 12m ago", "deploy line")

        // 4. New errors: on the new version, not on the previous one.
        let rows: [DeployErrors.Row] = [
            .init(version: "1.4.1", type: "TimeoutError", resource: "POST /orders", count: 9),
            .init(version: "1.4.2", type: "TimeoutError", resource: "POST /orders", count: 30),
            .init(version: "1.4.2", type: "TypeError", resource: "GET /orders/{id}", count: 14),
            .init(version: "1.4.2", type: "TypeError", resource: "GET /cart", count: 3),
            .init(version: "1.4.2", type: nil, resource: "GET /health", count: 2),
            .init(version: "1.4.2", type: "KeyError", resource: "GET /cart", count: 1),
            .init(version: "1.4.2", type: "ValueError", resource: "GET /cart", count: 1),
            .init(version: "1.4.0", type: "OldError", resource: "GET /old", count: 5),
        ]
        let fresh = DeployErrors.newOnes(rows, version: "1.4.2", previous: "1.4.1")
        expect(fresh.map(\.type) == ["TypeError", nil, "KeyError"] && fresh.first?.count == 17 && fresh.first?.resource == "GET /orders/{id}",
               "new errors (merged, most common first, top 3): \(fresh.map { $0.line })")
        expect(fresh.first?.line == "TypeError · GET /orders/{id} · 17×", "new error line: \(fresh.first?.line ?? "")")
        expect(DeployErrors.newOnes(rows, version: "1.4.2", previous: nil).isEmpty, "no previous version, nothing is new")
        expect(DeployErrors.newOnes(rows, version: "1.4.1", previous: "1.4.2").isEmpty, "everything the old one had is known")
        let scalar: [String: Any] = ["data": ["type": "scalar_response", "attributes": ["columns": [
            ["name": "@version", "type": "group", "values": [["1.4.1"], ["1.4.2"], ["1.4.2"]]],
            ["name": "@error.type", "type": "group", "values": [["TimeoutError"], ["TimeoutError"], ["TypeError"]]],
            ["name": "resource_name", "type": "group", "values": [["POST /orders"], ["POST /orders"], ["GET /cart"]]],
            ["name": "errors", "type": "number", "values": [9, 30, 4]],
        ]]]]
        let parsedRows = (try? JSONSerialization.data(withJSONObject: scalar)).flatMap(DeployErrors.parse) ?? []
        expect(parsedRows.count == 3 && DeployErrors.newOnes(parsedRows, version: "1.4.2", previous: "1.4.1").map(\.type) == ["TypeError"], "scalar answer parsed: \(parsedRows)")

        // 5. The request bodies.
        let link = DeployLink(service: "orders", operation: "http.request")
        let seriesText = DeployQueries.seriesBody(link, now: now).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(seriesText.contains("sum:trace.http.request.hits{service:orders AND (env:prod OR env:production)} by {env,version}.as_count()")
               && seriesText.contains("sum:trace.http.request.errors{") && seriesText.contains("p95:trace.http.request{service:orders AND (env:prod OR env:production)} by {env,version}")
               && !seriesText.contains("prod*"),
               "series body: \(seriesText.prefix(200))")
        let errorsText = DeployQueries.errorsBody(link, from: now - 3600, to: now).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(errorsText.contains("service:orders (env:prod OR env:production) status:error") && errorsText.contains("@error.type") && errorsText.contains("\"spans\"")
               && errorsText.contains("\"@version\"") && !errorsText.contains("\"version\""),
               "errors body: \(errorsText.prefix(200))")
        expect(DeployLink.clean("orders") == "orders" && DeployLink.clean("a b") == nil && DeployLink.clean("a}{env:x") == nil && DeployLink.clean("") == nil, "service names are cleaned")

        // 6. builds.json: the services map and the hidden services.
        func config(_ datadog: String) -> BuildsConfig.Datadog? {
            BuildsConfig.parse(Data("{\"datadog\": {\"monitors\": \"service:api\"\(datadog)}}".utf8))?.datadog
        }
        let plain = config("")
        expect(plain?.hiddenServices == ["leads*"] && plain?.services.isEmpty == true && plain?.watchdog == true, "defaults: hidden \(String(describing: plain?.hiddenServices))")
        let linked = config(", \"services\": {\"Acme/Orders-API\": \"orders\", \"web\": {\"service\": \"storefront\", \"operation\": \"express.request\"}, \"bad\": \"a b\"}, \"hiddenServices\": [\"Leads\", \"admin\"], \"watchdog\": false")
        expect(linked?.services["acme/orders-api"] == link && linked?.services["web"] == DeployLink(service: "storefront", operation: "express.request") && linked?.services.count == 2,
               "services map: \(String(describing: linked?.services))")
        expect(linked?.hiddenServices == ["leads", "admin"] && linked?.watchdog == false, "hidden list: \(String(describing: linked?.hiddenServices))")
        expect(BuildsConfig.parse(Data("{\"datadog\": {\"monitors\": \"x\", \"services\": {\"bad\": \"a b\"}}}".utf8))?.problems.contains { $0.contains("services bad") } == true, "a bad service name is reported")
        expect(config(", \"hiddenServices\": []")?.hiddenServices == [], "an empty hide list hides nothing")

        // 7. Which repo a push came from; a repo with no entry gets no check; a hidden service never does.
        let services = ["acme/orders-api": link, "web": DeployLink(service: "storefront", operation: "http.request"), "leads-site": DeployLink(service: "leads", operation: "http.request")]
        expect(DeployRepo.link(folder: "/w/anything", repo: "Acme/Orders-API", services: services) == link, "full repo key, any case")
        expect(DeployRepo.link(folder: "/w/anything", repo: "other/web", services: services)?.service == "storefront", "repo name alone")
        expect(DeployRepo.link(folder: "/w/web", repo: nil, services: services)?.service == "storefront", "folder name when git has no Bitbucket remote")
        expect(DeployRepo.link(folder: "/w/unlinked", repo: "acme/unlinked", services: services) == nil, "no entry, no deploy check")
        let sessions: [(folder: String, shippedAt: Double?)] = [("/w/a", now - 60), ("/w/b", now - 1300), ("/w/c", now - 30), ("/w/d", nil), ("/w/e", now - 10), ("/w/f", now + 600)]
        let repos = ["/w/a": "acme/orders-api", "/w/b": "other/web", "/w/c": "acme/unlinked", "/w/d": "acme/orders-api", "/w/e": "x/leads-site", "/w/f": "acme/orders-api"]
        let pushes = DeployRepo.pushes(sessions: sessions, repos: repos, services: services, hidden: ["leads*"], now: now)
        expect(pushes == ["orders": now - 60], "pushes: only a linked, recent, shown service: \(pushes)")

        // 8. The monitors of a hidden service are dropped, by tag, scope or the service inside the query.
        let list: [[String: Any]] = [
            ["id": 1, "name": "API errors", "status": "Alert", "tags": ["service:api", "env:production"], "query": "avg(last_5m):avg:trace.x{service:api} > 1"],
            ["id": 2, "name": "Lead form", "status": "Alert", "tags": ["env:production", "service:leads"]],
            ["id": 3, "name": "Lead queue", "status": "Warn", "tags": [], "scopes": ["service:Leads-CDP"]],
            ["id": 4, "name": "Leads in the name only", "status": "OK", "tags": ["service:api"]],
            ["id": 5, "name": "[LEADS] Error rate", "status": "Alert", "tags": [], "query": "sum(last_5m):sum:trace.express.request.errors{service:leads,env:production}.as_count() > 5"],
            ["id": 6, "name": "[LEADS] Mobile", "status": "OK", "tags": ["team:growth"], "query": "avg(last_1h):avg:trace.x{env:production AND service:leads-mobile} > 3"],
            ["id": 7, "name": "Misleading", "status": "OK", "tags": [], "query": "avg:x{service:leadership}"],
        ]
        let (kept, droppedMonitors) = ProdMonitor.parse(list, hidden: ["leads*"])
        expect(kept.map(\.id) == [1, 4, 7] && droppedMonitors.map(\.id) == [2, 3, 5, 6], "leads family monitors hidden: kept \(kept.map(\.id)) dropped \(droppedMonitors.map(\.id))")
        expect(ProdMonitor.parse(list, hidden: []).dropped.isEmpty, "nothing hidden with an empty list")
        expect(ProdMonitor.parse(list, hidden: ["leads"]).dropped.map(\.id) == [2, 5], "a plain entry hides that service alone")
        let family: Set<String> = ["leads*"]
        expect(DeployHidden.matches("leads", family) && DeployHidden.matches("Leads-App", family) && DeployHidden.matches("leads-cdp", family)
               && !DeployHidden.matches("leadership", family) && !DeployHidden.matches("api", family) && !DeployHidden.matches("misleads", family), "leads* is the service and its leads- family")
        expect(DeployHidden.services(inQuery: "avg:x{service:a, env:b AND service:\"leads-app\"}") == ["a", "leads-app"], "services in a query")

        // Incidents: by the service the fields name, else by the title.
        func incident(_ title: String, _ fields: [String: Any]) -> [String: Any] { ["title": title, "fields": fields] }
        expect(DeployHidden.incident(incident("Checkout down", ["services": ["value": ["leads-app"]]]), hidden: family), "incident: fields.services names a hidden service")
        expect(DeployHidden.incident(incident("Checkout down", ["service": ["value": "leads"]]), hidden: family), "incident: fields.service, a string")
        expect(!DeployHidden.incident(incident("Leads page slow", ["services": ["value": ["orders"]]]), hidden: family), "incident: a named service wins over the title")
        expect(DeployHidden.incident(incident("Leads page slow", [:]), hidden: family), "incident: no service field, the title names it")
        expect(!DeployHidden.incident(incident("Checkout down", [:]), hidden: family) && !DeployHidden.incident(incident("Leads page slow", [:]), hidden: []), "incident: others stay")

        // 9. Watchdog stories and deploy events from one events answer.
        let t0 = buildTime("2026-10-20T10:00:00.000Z") ?? 0
        let wnow = t0 + 600
        func event(_ id: String, _ stamp: String, _ title: String?, _ tags: [String], message: String? = nil) -> [String: Any] {
            var attributes: [String: Any] = ["timestamp": stamp, "tags": tags]
            if let title { attributes["attributes"] = ["title": title] }
            if let message { attributes["message"] = message }
            return ["id": id, "type": "event", "attributes": attributes]
        }
        let ongoing = "story_status:ongoing", anomaly = "story_type:logs_pattern_anomaly"
        let events: [String: Any] = ["data": [
            event("w1", "2026-10-20T10:00:00.000Z", "Anomalous latency on orders", ["source:watchdog", "service:orders", "env:production", ongoing, anomaly]),
            event("w2", "2026-10-20T09:59:00.000Z", "Anomalous latency on orders", ["service:orders", "env:prod", ongoing]),
            event("w3", "2026-10-20T09:58:00.000Z", "Error spike on leads-app", ["service:leads-app", "env:prod", ongoing]),
            event("w4", "2026-10-20T09:57:00.000Z", "Staging noise", ["service:orders", "env:staging", ongoing]),
            event("w5", "2026-10-20T09:56:00.000Z", nil, [], message: "Disk growth on db-1\nmore text"),
            event("w6", "2026-10-20T09:55:00.000Z", "New error logs were detected on leads", ["env:production", ongoing, anomaly]),
            event("w7", "2026-10-20T09:54:00.000Z", "Old story", ["service:orders", "env:prod", "story_status:resolved"]),
            event("w8", "2026-10-20T08:00:00.000Z", "Stale story", ["service:orders", "env:prod"]),
            event("d1", "2026-10-20T09:30:00.000Z", "New APM Deployment Version: ai_gateway_800fbcb",
                  ["source:change_tracking", "service:ai-gateway", "version:ai_gateway_800fbcb", "previous_version:ai_gateway_5c1d", "env:prod"]),
            event("d2", "2026-10-20T09:20:00.000Z", "New APM Deployment Version: 1.0.1", ["service:leads-app", "version:1.0.1"]),
        ]]
        let eventsData = (try? JSONSerialization.data(withJSONObject: events)) ?? Data()
        let stories = Watchdog.parse(eventsData, hidden: family, now: wnow) ?? []
        expect(stories.map(\.id) == ["w1", "w5"] && stories.first?.service == "orders" && stories.first?.status == "ongoing" && stories.last?.title == "Disk growth on db-1",
               "watchdog stories (ongoing or within the hour; leads, staging, resolved, deploy events left out): \(stories.map(\.id))")
        let deployEvents = Watchdog.parseDeploys(eventsData, hidden: family) ?? []
        expect(deployEvents == [DeployEvent(service: "ai-gateway", version: "ai_gateway_800fbcb", previous: "ai_gateway_5c1d", at: t0 - 1800)], "deploy events: \(deployEvents)")
        let watchdogItems = Watchdog.items(now: now)
        expect(watchdogItems.first { $0.name == "filter[query]" }?.value == "source:(watchdog OR change_tracking)" && watchdogItems.contains { $0.name == "sort" && $0.value == "-timestamp" },
               "one events request for both")
        expect(Watchdog.storyURL(site: "us5.datadoghq.com", id: "abc")?.absoluteString == "https://us5.datadoghq.com/watchdog/story/abc"
               && Watchdog.storyURL(site: "datadoghq.com", id: "abc")?.host == "app.datadoghq.com", "story links are on the org's own site")
        // The deploys list: events win over the same version in the metrics; the newest first.
        let seriesDeploys = [DeployEntry(version: "ai_gateway_800fbcb", previous: "ai_gateway_5c1d", at: t0 - 1500), DeployEntry(version: "x1", previous: "x0", at: t0 - 90000)]
        let merged = DeployFeed.merge(seriesDeploys, events: deployEvents + [DeployEvent(service: "orders", version: "9", previous: nil, at: t0)], service: "AI-Gateway")
        expect(merged.map(\.version) == ["ai_gateway_800fbcb", "x1"] && merged.first?.at == t0 - 1800 && merged.first?.previous == "ai_gateway_5c1d", "deploys feed: \(merged)")

        // 9b. A service that reports one constant version: the time since the push against an equal
        // stretch before it.
        func sinceCase(pushedAt: Double, before: (hits: Double, rate: Double, p95: Double)?, after: (hits: Double, rate: Double, p95: Double)) -> DeployAnalysis.Comparison? {
            var specs: [(version: String, env: String, from: Double, to: Double, hits: Double, errorRate: Double, p95: Double)] = []
            if let before { specs.append(("1.0.0", "prod", pushedAt - 3600, pushedAt, before.hits, before.rate, before.p95)) }
            specs.append(("1.0.0", "prod", pushedAt, now, after.hits, after.rate, after.p95))
            guard let merged = DeployAnalysis.parse(timeseries(specs, from: day, to: now - 300)) else { return nil }
            return DeployAnalysis.compare(merged, pushedAt: pushedAt, now: now, interval: 300)
        }
        let sinceWorse = sinceCase(pushedAt: now - 900, before: (600, 0.004, 0.18), after: (590, 0.021, 0.21))
        expect(sinceWorse?.sincePushAt == now - 900 && sinceWorse?.verdict?.state == .worse, "since push: worse \(String(describing: sinceWorse?.verdict?.line))")
        expect(sinceWorse?.verdict?.line.hasPrefix("since push · 15m vs 15m before: errors 0.4→2.1% ▲ · p95 180→210ms ▲") == true,
               "since push: line \(sinceWorse?.verdict?.line ?? "nil")")
        expect(sinceWorse?.verdict?.parts.first?.tone == .bad && sinceWorse?.verdict?.parts.last?.tone == .plain, "since push: only the worse parts are red")
        let sinceSame = sinceCase(pushedAt: now - 900, before: (600, 0.004, 0.18), after: (600, 0.004, 0.18))
        expect(sinceSame?.verdict?.state == .same, "since push: same \(String(describing: sinceSame?.verdict?.state))")
        let sinceEarly = sinceCase(pushedAt: now - 400, before: (600, 0.004, 0.18), after: (600, 0.004, 0.18))
        expect(sinceEarly?.verdict?.state == .collecting && sinceEarly?.verdict?.line.contains("collecting") == true, "since push: under two buckets is collecting: \(sinceEarly?.verdict?.line ?? "nil")")
        let sinceFresh = sinceCase(pushedAt: now - 900, before: nil, after: (600, 0.004, 0.18))
        expect(sinceFresh?.verdict?.state == .noPrevious && sinceFresh?.verdict?.line.contains("nothing before the push") == true, "since push: nothing before the push: \(sinceFresh?.verdict?.line ?? "nil")")
        // A version that changed after the push still gets the version comparison.
        if let merged = DeployAnalysis.parse(timeseries([("1.4.1", "prod", day, now - 900, 600, 0.004, 0.18), ("1.4.2", "prod", now - 900, now, 590, 0.021, 0.21)], from: day, to: now - 300)) {
            let byVersion = DeployAnalysis.compare(merged, pushedAt: now - 960, now: now, interval: 300)
            expect(byVersion.sincePushAt == nil && byVersion.verdict?.line.hasPrefix("v1.4.2 vs v1.4.1") == true, "version changed: version comparison \(byVersion.verdict?.line ?? "nil")")
            let older = DeployAnalysis.compare(merged, pushedAt: now - 300, now: now, interval: 300)
            expect(older.sincePushAt != nil, "a push after the last version change compares since the push")
        } else { expect(false, "version fixture parses") }
        // The label under a since-push report.
        expect(DeployVerdict.make(version: "1.0.0", previous: nil, new: VersionStats(hits: 100, errors: 1, p95: 0.1, minutes: 10), old: nil, sinceMinutes: 14).headline == "since push · 14m vs 14m before", "since push headline")

        // New errors since the push: seen after it, not in the stretch before it.
        let afterRows: [DeployErrors.Row] = [.init(version: "all", type: "TimeoutError", resource: "POST /orders", count: 12), .init(version: "all", type: "TypeError", resource: "GET /cart", count: 5)]
        let beforeRows: [DeployErrors.Row] = [.init(version: "all", type: "TimeoutError", resource: "POST /orders", count: 20)]
        expect(DeployErrors.newSince(after: afterRows, before: beforeRows).map(\.type) == ["TypeError"], "new since the push")
        expect(DeployErrors.newSince(after: afterRows, before: []).count == 2, "everything is new when nothing came before")
        // A spans answer with no version column (grouped by error type and resource only).
        let noVersion: [String: Any] = ["data": ["type": "scalar_response", "attributes": ["columns": [
            ["name": "@error.type", "type": "group", "values": [["TypeError"], ["TimeoutError"]]],
            ["name": "resource_name", "type": "group", "values": [["GET /cart"], ["POST /orders"]]],
            ["name": "errors", "type": "number", "values": [5, 12]],
        ]]]]
        let plainRows = (try? JSONSerialization.data(withJSONObject: noVersion)).flatMap(DeployErrors.parse) ?? []
        expect(plainRows.count == 2 && plainRows.allSatisfy { $0.version == "all" }, "spans without a version column: \(plainRows)")

        // Notes are kept per kind: the deploys read succeeding does not clear the errors note.
        var notes = DeployNotes()
        notes.set("errors", DeployScopes.errorsMissing)
        notes.clear("deploys")
        expect(notes.text == DeployScopes.errorsMissing, "an errors note survives a deploys success")
        notes.set("deploys", DeployScopes.deployMissing)
        expect(notes.text == DeployScopes.deployMissing, "the deploys note shows first")
        notes.clear("deploys"); notes.clear("errors")
        expect(notes.text == nil, "notes clear per kind")

        // The first errors read after a push costs two requests (after and before), and the services
        // share the allowance in turn, the longest-waiting first.
        let pair = DeployPlanner.due(pushes: ["a": now, "b": now], now: now + 70, lastSeries: ["a": now + 60, "b": now + 60], lastErrors: [:], wantsErrors: ["a", "b"], beforeNeeded: ["a", "b"], slow: 1, used: 0, allowance: 3)
        expect(pair.count == 1 && pair.first?.kind == .errors, "two services want errors with room for 3: one takes 2 requests, the other waits: \(pair)")
        let turn = DeployPlanner.due(pushes: ["a": now, "b": now], now: now + 100, lastSeries: ["a": now + 90, "b": now + 10], lastErrors: [:], wantsErrors: [], slow: 1, used: 0, allowance: 1)
        expect(turn == [.init(service: "b", kind: .series)], "the allowance goes to the service waiting longest, not the first by name: \(turn)")

        // 10. Polling only inside the 20 minutes after a push.
        let pushAt = now
        func dueAt(_ t: Double, last: Double = 0, errors: Set<String> = []) -> [DeployPlanner.Due] {
            DeployPlanner.due(pushes: ["orders": pushAt], now: t, lastSeries: ["orders": last], lastErrors: [:], wantsErrors: errors, slow: 1, used: 0, allowance: 36)
        }
        expect(dueAt(pushAt - 1).isEmpty, "nothing before the push")
        expect(dueAt(pushAt + 5) == [.init(service: "orders", kind: .series)], "due right after the push")
        expect(dueAt(pushAt + 1199, last: pushAt + 1130).count == 1, "still due at 19 min 59 s")
        expect(dueAt(pushAt + 1200).isEmpty && dueAt(pushAt + 1201).isEmpty && dueAt(pushAt + 7200).isEmpty, "nothing after 20 minutes")
        expect(dueAt(pushAt + 30, last: pushAt + 5).isEmpty, "the series every minute, not faster")
        expect(dueAt(pushAt + 70, last: pushAt + 30, errors: ["orders"]).map(\.kind) == [.errors], "the errors once there is a pair to compare")
        expect(dueAt(pushAt + 70, last: pushAt + 30).isEmpty, "no error read without a pair")
        expect(DeployPlanner.due(pushes: ["orders": pushAt], now: pushAt + 5, lastSeries: [:], lastErrors: [:], wantsErrors: [], slow: 1, used: 36, allowance: 36).isEmpty, "nothing past the hour's allowance")
        expect(DeployPlanner.due(pushes: ["orders": pushAt], now: pushAt + 5, lastSeries: ["orders": pushAt - 1], lastErrors: [:], wantsErrors: [], slow: 2, used: 0, allowance: 36).isEmpty, "half pace after a 429")

        // 11. The hourly budget. Worst case: three services pushed to without a break for two hours.
        for numbers in 0...3 {
            let allowance = DeployBudget.allowance(numbers: numbers, cap: DatadogSource.hourlyCap)
            expect(DeployBudget.worstCase(numbers: numbers, cap: DatadogSource.hourlyCap) <= DatadogSource.hourlyCap - DeployBudget.reserve,
                   "budget with \(numbers) numbers: \(DeployBudget.worstCase(numbers: numbers, cap: DatadogSource.hourlyCap))")
            expect(allowance <= DeployBudget.most, "allowance \(allowance)")
        }
        let allowance = DeployBudget.allowance(numbers: 2, cap: DatadogSource.hourlyCap)
        expect(allowance == 36 && DeployBudget.worstCase(numbers: 2, cap: DatadogSource.hourlyCap) == 144, "two numbers: allowance \(allowance), worst case \(DeployBudget.worstCase(numbers: 2, cap: DatadogSource.hourlyCap))")
        var used: [Double] = [], lastSeries: [String: Double] = [:], lastErrors: [String: Double] = [:]
        var peak = 0
        var t = now
        while t < now + 7200 {
            used.removeAll { t - $0 > 3600 }
            let busy = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { ($0, t - 10) })
            for due in DeployPlanner.due(pushes: busy, now: t, lastSeries: lastSeries, lastErrors: lastErrors, wantsErrors: ["a", "b", "c"], slow: 1, used: used.count, allowance: allowance) {
                if due.kind == .series { lastSeries[due.service] = t } else { lastErrors[due.service] = t }
                used.append(t)
            }
            peak = max(peak, used.count)
            t += 2
        }
        expect(peak <= allowance, "three busy services never pass the allowance: peak \(peak) of \(allowance)")
        expect(DeployBudget.standing(numbers: 2) + peak <= DatadogSource.hourlyCap, "standing polls plus deploy checks stay under the cap: \(DeployBudget.standing(numbers: 2) + peak) of \(DatadogSource.hourlyCap)")
        // One service, one push: what its 20 minutes cost.
        used = []; lastSeries = [:]; lastErrors = [:]
        t = pushAt
        while t < pushAt + 3600 {
            for due in DeployPlanner.due(pushes: ["orders": pushAt], now: t, lastSeries: lastSeries, lastErrors: lastErrors, wantsErrors: ["orders"], slow: 1, used: used.count, allowance: allowance) {
                if due.kind == .series { lastSeries[due.service] = t } else { lastErrors[due.service] = t }
                used.append(t)
            }
            t += 2
        }
        expect(used.count >= 20 && used.count <= allowance && used.allSatisfy { $0 < pushAt + DeployWindow.seconds }, "one push costs \(used.count) requests, all inside its 20 minutes")
        print("deploy check budget: \(used.count) requests for one push; worst hour with two numbers \(DeployBudget.worstCase(numbers: 2, cap: DatadogSource.hourlyCap)) of \(DatadogSource.hourlyCap) (standing \(DeployBudget.standing(numbers: 2)) + deploy checks \(peak))")

        // 12. The sign-in's scopes: an old sign-in lacks apm_read and events_read.
        let old = ["incident_read", "monitors_read", "timeseries_query"]
        expect(DeployScopes.note(granted: old, needs: "apm_read", message: DeployScopes.deployMissing) == "Sign in again to see deploy checks", "missing apm_read: the note")
        expect(DeployScopes.note(granted: old, needs: "events_read", message: DeployScopes.watchdogMissing) == "Sign in again to see Watchdog", "missing events_read: the note")
        expect(DeployScopes.note(granted: DatadogOAuth.scopes, needs: "apm_read", message: "x") == nil && DeployScopes.note(granted: nil, needs: "apm_read", message: "x") == nil, "no note with the scope, or with keys")
        expect(DatadogOAuth.scopes.contains("apm_read") && DatadogOAuth.scopes.contains("events_read") && !old.contains("apm_read"), "the sign-in asks for apm_read and events_read")

        // 13. The collapsed strip's chips come after a prod alert and before a build failure.
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: true, deployWorse: true, subagents: 0, building: 0) == .deployWorse, "deploy chip before a failed build")
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: true, buildFailure: false, deployWorse: true, watchdog: true, subagents: 0, building: 0) == .prodAlert, "a prod alert comes first")
        expect(WingSlot.pick(waiting: 0, justDone: false, prodAlert: false, buildFailure: true, watchdog: true, subagents: 0, building: 0) == .watchdog, "watchdog chip")

        print("deploy check selfcheck: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
