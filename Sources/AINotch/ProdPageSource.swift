import Foundation

// What the Prod page asks Datadog, only while it is open and the screen is not locked. It reuses
// what the polls already read (the monitor search's trigger times, the incident search, the last
// Watchdog/deploy events) and adds, per range:
//   - one timeseries request per configured health number, every 60 s (`.series`),
//   - one events request for monitor alerts (`source:alert`), every 2 minutes (`.history`),
//   - on 7 d only, one events request for Watchdog and deploys, every 5 minutes (`.history`); on 1 h
//     and 24 h the poller's own 24-hour answer is read again, with no request.
// Page requests are counted apart from the polls' (`pageRequests`, cap 240 an hour), so reading the
// page never pauses them; the 429/hold/403 handling in `send` is the same.

extension DatadogSource {
    /// The page opened, closed or changed its range: what is stored is shown at once, what is
    /// stale is read on the next tick (within 2 s).
    func setPage(open: Bool, range: ProdRange) {
        page.open = open
        page.range = range
        if open { publishPage() }
    }

    func tickPage(_ config: BuildsConfig.Datadog, locked: Bool) async {
        let now = self.now
        pageRequests.removeAll { now - $0 > 3600 }
        guard page.open, !locked, via != nil else { return }
        let range = page.range
        let granted = via == .signIn ? await DatadogAuth.shared.grantedScopes(site: config.site) : nil
        func missing(_ scope: String) -> Bool { granted.map { !$0.contains(scope) } ?? false }
        let hidden = Set(config.hiddenServices)

        // The health numbers' series.
        if config.health.isEmpty {
            page.series[range] = nil
            page.notes["series"] = nil
        } else if missing("timeseries_query") {
            page.notes["series"] = "Sign in again to see the numbers' history (timeseries_query was not granted)."
        } else if now >= noAccessUntil[.series] ?? 0, now >= holdUntil[.series] ?? 0,
                  now - (page.series[range]?.at ?? 0) >= ProdPagePlan.seriesEvery {
            if pageRequests.count + config.health.count <= ProdPagePlan.hourlyCap {
                await fetchPageSeries(config, range: range)
            } else {
                page.notes["series"] = "Paused: AI Notch's own cap of \(ProdPagePlan.hourlyCap) page requests an hour was reached."
            }
        }

        // Monitor alerts and recoveries.
        if missing("events_read") {
            page.notes["alerts"] = "Sign in again to see alert history (events_read was not granted)."
            page.notes["events"] = "Sign in again to see Watchdog and deploys (events_read was not granted)."
        } else {
            if now >= noAccessUntil[.history] ?? 0, now >= holdUntil[.history] ?? 0,
               now - (page.alerts[range]?.at ?? 0) >= ProdPagePlan.alertsEvery, pageRequests.count < ProdPagePlan.hourlyCap {
                await fetchPageAlerts(range: range, hidden: hidden)
            }
            // Watchdog and deploys: the poller's answer for 1 h and 24 h when it has one, else a request.
            if range != .week, let stash = page.eventsData, now - stash.at < 1200 {
                if let entries = ProdTimelineEntry.stories(stash.data, hidden: hidden) {
                    page.events[range] = (entries, stash.at)
                    page.notes["events"] = nil
                }
            } else if now >= noAccessUntil[.history] ?? 0, now >= holdUntil[.history] ?? 0,
                      now - (page.events[range]?.at ?? 0) >= ProdPagePlan.weekEventsEvery, pageRequests.count < ProdPagePlan.hourlyCap {
                await fetchPageEvents(range: range, hidden: hidden)
            }
        }
        publishPage()
    }

    private func fetchPageSeries(_ config: BuildsConfig.Datadog, range: ProdRange) async {
        guard let url = url("/api/v2/query/timeseries", []) else { return }
        let to = (now * 1000).rounded()
        var all: [ProdSeries] = []
        var firstFailure: String?
        for health in config.health {
            guard via != nil, now >= noAccessUntil[.series] ?? 0, now >= holdUntil[.series] ?? 0 else { break }
            let body: [String: Any] = ["data": ["type": "timeseries_request", "attributes": [
                "from": Int64(to - range.seconds * 1000), "to": Int64(to), "interval": range.intervalMs,
                "queries": health.queries.map { ["data_source": "metrics", "name": $0.name, "query": $0.query] },
                "formulas": [["formula": health.formula]],
            ]]]
            var series = ProdSeries(label: health.label, unit: health.unit, amber: health.amber)
            if let json = try? JSONSerialization.data(withJSONObject: body), let data = await send(.series, url, body: json) {
                if let values = ProdSeriesParse.values(data, scale: health.scale) {
                    series.values = values
                    if values.isEmpty { series.note = "no data in \(range.words)" }
                } else {
                    series.note = "unexpected answer"
                }
            } else {
                series.note = failure ?? "not read"
                firstFailure = firstFailure ?? failure
            }
            all.append(series)
        }
        guard all.count == config.health.count else { page.notes["series"] = firstFailure; return }
        // A failed number keeps its earlier values (marked stale by the note) instead of a hole.
        let before = page.series[range]?.series ?? []
        for index in all.indices where all[index].values.isEmpty && all[index].note != nil && index < before.count && before[index].label == all[index].label {
            let note = all[index].note
            all[index] = before[index]
            all[index].note = note.map { "\($0) (showing the last read)" }
        }
        page.series[range] = (all, now)
        page.notes["series"] = all.allSatisfy({ $0.values.isEmpty }) ? firstFailure : nil
    }

    private func fetchPageAlerts(range: ProdRange, hidden: Set<String>) async {
        let items = [URLQueryItem(name: "filter[query]", value: "source:alert"),
                     URLQueryItem(name: "filter[from]", value: String(Int64((now - range.seconds) * 1000))),
                     URLQueryItem(name: "filter[to]", value: String(Int64(now * 1000))),
                     URLQueryItem(name: "page[limit]", value: "100"),
                     URLQueryItem(name: "sort", value: "-timestamp")]
        guard let url = url("/api/v2/events", items) else { return }
        guard let data = await send(.history, url) else {
            // Without the events, what the monitor search knows still shows (page.published reads it).
            page.notes["alerts"] = failure
            page.alerts[range] = (page.alerts[range]?.entries ?? [], now)
            return
        }
        guard let entries = ProdTimelineEntry.alerts(data, hidden: hidden, monitorIds: page.monitorIdsComplete ? page.monitorIds : nil) else {
            page.notes["alerts"] = "unexpected answer"
            return
        }
        page.alerts[range] = (entries, now)
        page.notes["alerts"] = nil
    }

    private func fetchPageEvents(range: ProdRange, hidden: Set<String>) async {
        guard let url = url("/api/v2/events", Watchdog.items(now: now, lookback: range.seconds)) else { return }
        guard let data = await send(.history, url) else {
            page.notes["events"] = failure
            page.events[range] = (page.events[range]?.entries ?? [], now)
            return
        }
        guard let entries = ProdTimelineEntry.stories(data, hidden: hidden) else {
            page.notes["events"] = "unexpected answer"
            return
        }
        page.events[range] = (entries, now)
        page.notes["events"] = nil
    }

    /// What the page shows from Datadog now: the range's series, and one list of entries from the
    /// incident search, the monitors' last triggers, the alert events, and the stories and deploys.
    func publishPage() {
        guard page.open, let onPage else { return }
        let range = page.range
        var data = ProdPageData()
        data.range = range
        data.series = page.series[range]?.series ?? []
        data.seriesAt = page.series[range]?.at ?? 0
        data.remote = ProdTimelineEntry.triggers(snapshot.monitors) + page.incidentEntries
            + (page.alerts[range]?.entries ?? []) + (page.events[range]?.entries ?? [])
        data.remoteAt = max(page.alerts[range]?.at ?? 0, page.events[range]?.at ?? 0, snapshot.incidentsAt)
        data.notes = page.notes
        data.requestsLastHour = pageRequests.filter { now - $0 <= 3600 }.count
        // The count alone changes every request: sent only with other changes or once a minute.
        var compare = data, before = page.published
        compare.requestsLastHour = 0
        before.requestsLastHour = 0
        guard compare != before || abs(data.requestsLastHour - page.published.requestsLastHour) > 0 && now - pageSentAt > 60 else { return }
        page.published = data
        pageSentAt = now
        onPage(data)
    }
}
