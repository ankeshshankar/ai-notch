import Foundation

// Dev check of Cursor's usage parsing and totals, never the app: `AINotch --cursor-usage-selfcheck`.
// Made-up dashboard events go through the same parser and ledger the app uses (full and compact
// rows, requests Cursor did not charge, free credit, repeated rows of one request, a page that is
// not the documented shape), and each total is checked. Exits 1 on any failure; no network.
enum CursorUsageSelfCheck {
    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--cursor-usage-selfcheck") else { return }
        exit(run())
    }

    /// Local noon on a March day, in milliseconds as the dashboard writes it (a string).
    private static func stamp(_ day: Int, hour: Int = 12, second: Int = 0) -> String {
        let parts = DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: 0, second: second)
        let date = Calendar.current.date(from: parts) ?? Date()
        return String(Int(date.timeIntervalSince1970 * 1000))
    }

    /// A made-up request: one conversation and model at `time`, with a fixed size.
    private static func request(_ id: String, at time: Double) -> CursorEvent {
        var tally = TokenTally()
        tally.input = 10
        tally.output = 1
        tally.cost = 0.10
        return CursorEvent(key: "\(id)\u{0}m\u{0}\(Int(time * 1000))", time: time, model: "m", tally: tally)
    }

    /// Catch-up runs that take several chunks, and a dashboard that misbehaves.
    private static func runCatchUpChecks(_ check: (String, Bool) -> Void) {
        let base = 1_800_000_000.0
        let cutoff = base - CursorLedger.overlap
        // History already read: one request at `base` is counted.
        func complete() -> CursorLedger {
            var ledger = CursorLedger()
            ledger.merge([request("old", at: base)], cutoff: nil)
            ledger.finishBackfill()
            return ledger
        }
        // Eight requests half an hour apart, newest first; the last is older than the cutoff.
        let listed = (0..<8).map { request("r\($0)", at: base + 7200 - Double($0) * 1800) }
        let newcomer = request("new", at: base + 9000)
        // Chunk one is read; then a new request arrives, so chunk two starts a row early.
        let first = Array(listed[0..<4])
        let second = [newcomer] + Array(listed[3...])
        // Seven of the eight are inside the cutoff, plus the newcomer and the one already counted.
        let expectedEvents = 7 + 1 + 1

        var ledger = complete()
        check("catch-up: starts at page 1, an hour back", ledger.nextRequest().page == 1 && ledger.nextRequest().cutoff == cutoff)
        let one = ledger.take(first, nextPage: 3, ok: true, cutoff: cutoff)
        check("catch-up: a full chunk goes on", one.goOn && !one.stalled && ledger.run == CursorLedger.Run(page: 3, cutoff: cutoff))
        check("catch-up: the first chunk's requests stay remembered", ledger.recent.count == 5)
        let two = ledger.take(second, nextPage: nil, ok: true, cutoff: cutoff)
        check("catch-up: a page that moved is not counted twice", ledger.events == expectedEvents && !two.goOn)
        check("catch-up: totals", ledger.total.input == 10 * expectedEvents && abs(ledger.total.cost - 0.10 * Double(expectedEvents)) < 0.000_001)
        check("catch-up: ends with no run and only the last hour kept", ledger.run == nil && ledger.recent.count == 3)

        // A failed poll in the middle: the next one resumes at the saved page, same cutoff.
        var failed = complete()
        _ = failed.take(first, nextPage: 3, ok: false, cutoff: cutoff)
        check("failed poll: resumes at the failed page", failed.nextRequest().page == 3 && failed.nextRequest().cutoff == cutoff)

        // The app quits between the chunks: the saved run is what the next launch goes on from.
        var saved = complete()
        _ = saved.take(first, nextPage: 3, ok: true, cutoff: cutoff)
        let reloaded = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode(CursorLedger.self, from: $0) }
        check("restart: the run survives a save and load", reloaded?.run == CursorLedger.Run(page: 3, cutoff: cutoff))
        var resumed = reloaded ?? CursorLedger()
        check("restart: goes on at the saved page and time", resumed.nextRequest().page == 3 && resumed.nextRequest().cutoff == cutoff)
        _ = resumed.take(second, nextPage: nil, ok: true, cutoff: resumed.nextRequest().cutoff)
        check("restart: nothing lost or counted twice", resumed.events == expectedEvents && resumed.run == nil)
        // An old ledger without a run still loads.
        let oldJSON = Data(#"{"complete":true,"nextPage":1,"newestAt":5,"events":0,"byDay":{},"recent":{}}"#.utf8)
        check("restart: a ledger saved before runs loads", (try? JSONDecoder().decode(CursorLedger.self, from: oldJSON))?.run == nil)

        // Backfill that keeps its page across restarts, and finishes on the last page.
        var backfill = CursorLedger()
        _ = backfill.take(first, nextPage: 21, ok: true, cutoff: nil)
        check("backfill: remembers its page", backfill.nextRequest().page == 21 && backfill.nextRequest().cutoff == nil && !backfill.complete)
        let done = backfill.take(second, nextPage: nil, ok: true, cutoff: nil)
        check("backfill: finishes", backfill.complete && !done.goOn && backfill.run == nil)

        // A dashboard that ignores the page number: the same full page each time.
        let page = CursorPage(events: (0..<50).map { request("p\($0)", at: base - Double($0)) }, rowCount: 50, oldest: base - 49, total: 400)
        var paging = CursorPaging(cutoff: nil)
        check("repeating page: the first is read", paging.verdict(page: 1, fetched: page) == .next)
        check("repeating page: the same page again stops the poll", paging.verdict(page: 2, fetched: page) == .repeated)
        // During the first backfill a repeat does not end it: the page is kept and tried again.
        var stuck = CursorLedger()
        _ = stuck.take(page.events, nextPage: 21, ok: true, cutoff: nil)
        let again = stuck.take(page.events, nextPage: 41, ok: true, cutoff: nil)
        check("repeating chunk: stalls, stays at its page, history not complete",
              again.stalled && !again.goOn && !again.gaveUp && !stuck.complete && stuck.nextRequest().page == 21 && stuck.failures == 1 && !stuck.partial)
        // Pages read before the poll saw the repeat were new: go on from where it showed.
        var progress = CursorLedger()
        let poll = progress.take(Array(listed[0..<4]), nextPage: 3, ok: false, cutoff: nil, repeated: true)
        check("repeat after new pages: goes on from there, not complete", poll.stalled && !poll.gaveUp && !progress.complete && progress.nextRequest().page == 3 && progress.failures == 0)
        // A good chunk in between clears the tries.
        _ = stuck.take(second, nextPage: 41, ok: true, cutoff: nil)
        check("repeating chunk: new events clear the tries", stuck.failures == 0 && stuck.nextRequest().page == 41 && !stuck.complete)
        // Still repeating after a few tries: the history is finished as incomplete, and says so.
        var gave = CursorLedger()
        _ = gave.take(page.events, nextPage: 21, ok: true, cutoff: nil)
        var last = CursorLedger.Outcome(changed: false, goOn: false, stalled: false, gaveUp: false)
        for _ in 0..<CursorLedger.maxTries { last = gave.take(page.events, nextPage: 41, ok: true, cutoff: nil) }
        check("repeating chunk: gives up after the tries, marked partial", last.gaveUp && gave.partial && gave.complete && gave.nextRequest().page == 1)
        let savedPartial = (try? JSONEncoder().encode(gave)).flatMap { try? JSONDecoder().decode(CursorLedger.self, from: $0) }
        check("partial: kept across a save and load", savedPartial?.partial == true && savedPartial == gave)
        let oldFields = Data(#"{"complete":true,"nextPage":1,"newestAt":5,"events":0,"byDay":{},"recent":{}}"#.utf8)
        let unmarked = try? JSONDecoder().decode(CursorLedger.self, from: oldFields)
        check("partial: a ledger without the fields loads as complete", unmarked?.partial == false && unmarked?.failures == 0)
        // A catch-up that repeats just ends; nothing is marked.
        var head = complete()
        _ = head.take(first, nextPage: 3, ok: true, cutoff: cutoff)
        let ended = head.take(first, nextPage: 5, ok: true, cutoff: cutoff)
        check("catch-up repeat: ends without a mark", !ended.goOn && !head.partial && head.run == nil)

        // A page of a catch-up that Cursor keeps answering badly does not block the head for good.
        var bad = complete()
        _ = bad.take(first, nextPage: 3, ok: true, cutoff: cutoff)
        var badLast = CursorLedger.Outcome(changed: false, goOn: false, stalled: false, gaveUp: false)
        for tries in 1...CursorLedger.maxTries {
            check("bad page: try \(tries) keeps the run", tries == CursorLedger.maxTries || bad.run?.page == 3)
            badLast = bad.take([], nextPage: 3, ok: false, cutoff: cutoff, pageFailed: true)
        }
        check("bad page: after the tries the run is dropped and the gap marked", badLast.gaveUp && bad.run == nil && bad.partial && bad.nextRequest().page == 1)
        // Being offline is no page's fault: it never counts.
        var offline = complete()
        _ = offline.take(first, nextPage: 3, ok: true, cutoff: cutoff)
        for _ in 0..<(CursorLedger.maxTries + 2) { _ = offline.take([], nextPage: 3, ok: false, cutoff: cutoff) }
        check("offline: never gives up on a run", offline.run?.page == 3 && !offline.partial && offline.failures == 0)
        // A bad first page loses nothing: the head is simply read again.
        var head1 = complete()
        for _ in 0..<CursorLedger.maxTries { _ = head1.take([], nextPage: 1, ok: false, cutoff: cutoff, pageFailed: true) }
        check("bad first page: no gap marked", !head1.partial && head1.run == nil)

        // No end in sight: the dashboard's own count bounds the pages.
        var capped = CursorPaging(cutoff: nil)
        let pages = (400 + 49) / 50 + CursorPaging.margin
        var lastVerdict = CursorPaging.Verdict.next
        for number in 1...pages {
            let fresh = CursorPage(events: (0..<50).map { request("q\(number)-\($0)", at: base - Double(number * 100 + $0)) }, rowCount: 50, oldest: nil, total: 400)
            lastVerdict = capped.verdict(page: number, fetched: fresh)
        }
        check("page cap: ends at the count's pages plus a margin", lastVerdict == .end)
        let short = CursorPage(events: [request("s", at: base)], rowCount: 1, oldest: base, total: 1)
        var lastPaging = CursorPaging(cutoff: nil)
        check("last page: a short page ends it", lastPaging.verdict(page: 1, fetched: short) == .end)
        let old = CursorPage(events: [request("o", at: base - 7200)], rowCount: 50, oldest: base - 7200, total: 900)
        var cutPaging = CursorPaging(cutoff: cutoff)
        check("cutoff: a page reaching it ends the poll", cutPaging.verdict(page: 1, fetched: old) == .end)

        check("redirect refused: the reason says so", CursorUsageSource.failureReason(status: 302).contains("redirect") && CursorUsageSource.failureReason(status: 500) == "Cursor answered HTTP 500")

        // The sign-in goes to cursor.com over https only.
        check("redirect: cursor.com is followed", CursorRedirectGuard.allows(URL(string: "https://cursor.com/api/x")))
        check("redirect: www.cursor.com is followed", CursorRedirectGuard.allows(URL(string: "https://www.cursor.com/")))
        check("redirect: another host is refused", !CursorRedirectGuard.allows(URL(string: "https://evil.example/api")))
        check("redirect: a look-alike host is refused", !CursorRedirectGuard.allows(URL(string: "https://cursor.com.evil.example/")))
        check("redirect: plain http is refused", !CursorRedirectGuard.allows(URL(string: "http://cursor.com/")))
    }

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }

        let rows: [[String: Any]] = [
            // The live sample: included in the plan, full token usage.
            ["timestamp": stamp(5), "model": "grok-4.7-high", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
             "conversationId": "c1", "isTokenBasedCall": true, "chargedCents": 134.7716064453125,
             "tokenUsage": ["inputTokens": 164_774, "outputTokens": 40_724, "cacheReadTokens": 1_547_648, "totalCents": 134.7716064453125]],
            // Compact form, with the cache write.
            ["timestamp": stamp(5, hour: 13), "model": "claude-4.5-sonnet", "kind": "USAGE_EVENT_KIND_USAGE_BASED",
             "conversationId": "c2", "chargedCents": 50, "inn": 1000, "out": 200, "cacheR": 3000, "cacheW": 400],
            // Not charged: the tokens count, the cost does not.
            ["timestamp": stamp(5, hour: 14), "model": "grok-4.7-high", "kind": "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED",
             "conversationId": "c3", "chargedCents": 12,
             "tokenUsage": ["inputTokens": 500, "outputTokens": 0, "cacheReadTokens": 0, "totalCents": 12]],
            // Free credit: charged cents are 0, the token total is what the plan counted.
            ["timestamp": stamp(6), "model": "gpt-5", "kind": "USAGE_EVENT_KIND_FREE_CREDIT",
             "conversationId": "c4", "chargedCents": 0,
             "tokenUsage": ["inputTokens": 2000, "outputTokens": 100, "cacheReadTokens": 0, "cacheWriteTokens": 50, "totalCents": 25]],
            // A request Cursor did not meter by tokens: nothing to count.
            ["timestamp": stamp(6, hour: 13), "model": "grok-4.7-high", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
             "conversationId": "c5", "isTokenBasedCall": false, "chargedCents": 0],
            // The same request twice, read at two points of its stream: the larger one counts.
            ["timestamp": stamp(6, hour: 14), "model": "gpt-5", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
             "conversationId": "c6", "chargedCents": 10, "tokenUsage": ["inputTokens": 100, "outputTokens": 10, "totalCents": 10]],
            ["timestamp": stamp(6, hour: 14), "model": "gpt-5", "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
             "conversationId": "c6", "chargedCents": 30, "tokenUsage": ["inputTokens": 100, "outputTokens": 10, "totalCents": 30]],
        ]
        let page1 = (try? JSONSerialization.data(withJSONObject: ["totalUsageEventsCount": 7, "usageEventsDisplay": rows])) ?? Data()
        guard let page = CursorEvents.parse(page1) else {
            print("FAIL the canned page did not parse")
            return 1
        }
        check("page: 7 rows read", page.rowCount == 7)
        check("page: the unmetered row carries no usage", page.events.count == 6)

        let byConversation = Dictionary(grouping: page.events) { String($0.key.split(separator: "\u{0}", omittingEmptySubsequences: false)[0]) }
        let sample = byConversation["c1"]?.first?.tally
        check("full row: tokens", sample?.input == 164_774 && sample?.output == 40_724 && sample?.cacheRead == 1_547_648 && sample?.cacheWrite == 0)
        check("full row: cost is the charged cents", near(sample?.cost ?? 0, 1.347716064453125))
        let compact = byConversation["c2"]?.first?.tally
        check("compact row: tokens", compact?.input == 1000 && compact?.output == 200 && compact?.cacheRead == 3000 && compact?.cacheWrite == 400)
        check("compact row: cost", near(compact?.cost ?? -1, 0.50))
        let free = byConversation["c4"]?.first?.tally
        check("free credit: cost is the token total's cents", near(free?.cost ?? -1, 0.25))
        let notCharged = byConversation["c3"]?.first?.tally
        check("not charged: tokens counted, cost 0", notCharged?.input == 500 && notCharged?.cost == 0)

        var ledger = CursorLedger()
        check("merge: reports a change", ledger.merge(page.events, cutoff: nil))
        let total = ledger.total
        // c6 once, at 30 cents: 1.347716 + 0.50 + 0 + 0.25 + 0.30.
        check("totals: 5 requests", ledger.events == 5)
        check("totals: input", total.input == 164_774 + 1000 + 500 + 2000 + 100)
        check("totals: output", total.output == 40_724 + 200 + 0 + 100 + 10)
        check("totals: cache read", total.cacheRead == 1_547_648 + 3000)
        check("totals: cache write", total.cacheWrite == 400 + 50)
        check("totals: cost", near(total.cost, 1.347716064453125 + 0.50 + 0 + 0.25 + 0.30))
        let day5 = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12))
        let key5 = day5.map { UsageScanner.day(of: $0.timeIntervalSince1970) } ?? ""
        check("per day: the 5th has two models", key5 == "2026-03-05" && ledger.byDay[key5]?.count == 2)
        check("per day: the 5th's grok total", ledger.byDay[key5]?["grok-4.7-high"]?.input == 164_774 + 500)
        check("per day: two days", ledger.byDay.count == 2)

        // Reading the same page again, in a backfill that moved by a row, counts nothing twice.
        check("again: no change", !ledger.merge(page.events, cutoff: nil) && ledger.total == total && ledger.events == 5)

        // A request still streaming when first read grows on a later read: it replaces, not adds.
        var growing = CursorEvents.event(from: rows[5])!
        growing.tally.cost = 0.80
        growing.tally.output = 40
        check("later reading: replaces", ledger.merge([growing], cutoff: nil) && ledger.events == 5)
        check("later reading: new totals", near(ledger.total.cost, total.cost - 0.30 + 0.80) && ledger.total.output == total.output - 10 + 40)

        // Once complete, only the last hour is remembered, and older rows are taken as counted.
        ledger.finishBackfill()
        check("complete: keeps only recent requests", ledger.complete && ledger.recent.count == 1 && ledger.events == 5)
        let cutoff = ledger.newestAt - CursorLedger.overlap
        let before = ledger.total
        check("poll: old rows are not counted again", !ledger.merge(page.events, cutoff: cutoff) || ledger.total.input == before.input)
        var fresh = CursorEvents.event(from: rows[0])!
        fresh.key = "c9\u{0}grok-4.7-high\u{0}1"
        fresh.time = ledger.newestAt + 60
        check("poll: a new request is added", ledger.merge([fresh], cutoff: cutoff) && ledger.events == 6)
        check("poll: and only once", !ledger.merge([fresh], cutoff: cutoff) && ledger.events == 6)

        // Shapes: the ledger survives a round trip, and an unexpected answer is not guessed at.
        let round = (try? JSONEncoder().encode(ledger)).flatMap { try? JSONDecoder().decode(CursorLedger.self, from: $0) }
        check("ledger: survives a save and load", round == ledger)
        check("shape: an empty account", CursorEvents.parse(Data(#"{"totalUsageEventsCount":0}"#.utf8))?.events.isEmpty == true)
        check("shape: not the documented answer", CursorEvents.parse(Data(#"{"error":"nope"}"#.utf8)) == nil)
        check("shape: not JSON", CursorEvents.parse(Data("<html>".utf8)) == nil)
        check("shape: events of the wrong type", CursorEvents.parse(Data(#"{"usageEventsDisplay":"x"}"#.utf8)) == nil)

        runCatchUpChecks(check)

        // The cookie: the token's subject (percent-encoded), then the token.
        let claims = Data(#"{"sub":"auth0|user_1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let fakeToken = "e30.\(claims).sig"
        check("cookie: subject and token", (try? CursorUsageSource.cookie(for: fakeToken)) == "WorkosCursorSessionToken=auth0%7Cuser_1%3A%3A\(fakeToken)")
        check("cookie: a token without a subject is refused", (try? CursorUsageSource.cookie(for: "nope")) == nil)

        print(failures == 0 ? "cursor usage selfcheck: all passed" : "cursor usage selfcheck: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
