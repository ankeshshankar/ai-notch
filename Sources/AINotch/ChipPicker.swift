import Foundation
import NotchCore

// The footer's status chips: every present chip shows, in one fixed order; the rule for the form
// each takes and for the rare overflow is one pure function, checked on made-up widths
// (`AINotch --chips-selfcheck`). A chip that does not fit stays reachable in the "…" / "+n" menu.

/// A status source with a chip.
enum FooterChip: String, CaseIterable {
    case prod, vpn, ram, limit, prs, commands

    /// The fixed order the chips keep, whatever their state (like `SessionOrder`).
    static let order: [FooterChip] = [.prod, .vpn, .ram, .limit, .prs, .commands]

    /// The panel this chip's section is (nil: Prod's own panel is `prodPanel`).
    var panel: String {
        switch self {
        case .prod: return NotchController.prodPanel
        case .vpn: return NotchController.vpnPanel
        case .ram: return NotchController.machinePanel
        case .limit: return "Usage"
        case .prs: return NotchController.pullRequestsPanel
        case .commands: return NotchController.commandsPanel
        }
    }
}

/// How much a chip's source needs a look, most urgent last.
enum ChipTone: Int, Comparable {
    case calm, news, warning, alert
    static func < (a: ChipTone, b: ChipTone) -> Bool { a.rawValue < b.rawValue }
}

struct ChipInput: Equatable {
    var chip: FooterChip
    /// Set up and showing something: an unconfigured source is never present.
    var present: Bool
    var tone: ChipTone
    /// Prod only: snoozed counts as calm, whatever its level.
    var snoozed = false

    var effectiveTone: ChipTone { snoozed ? .calm : tone }
}

/// A present chip's measured widths, one per form it can take, widest first: step 0 is its full
/// wording, the last step its compact form (a chip with one form has one step). Steps in between
/// drop the secondary text ("Prod 2 alerting · p95 210ms" -> "Prod 2 alerting" -> "Prod 2").
struct ChipWidth: Equatable {
    var chip: FooterChip
    var tone: ChipTone
    var steps: [Double]

    init(chip: FooterChip, tone: ChipTone, steps: [Double]) {
        self.chip = chip
        self.tone = tone
        self.steps = steps.isEmpty ? [0] : steps
    }

    init(chip: FooterChip, tone: ChipTone, compact: Double, full: Double) {
        self.init(chip: chip, tone: tone, steps: full > compact ? [full, compact] : [compact])
    }

    var full: Double { steps[0] }
    var compact: Double { steps[steps.count - 1] }
    var last: Int { steps.count - 1 }
    func width(at step: Int) -> Double { steps[min(max(step, 0), last)] }
}

struct ChipChoice: Equatable {
    /// Every present chip that fits, in the fixed order, with the step of its form (0: full wording).
    var shown: [FooterChip: Int]
    var order: [FooterChip]
    /// The present chips that did not fit, in the fixed order: they wait in the "…" / "+n" menu.
    var hidden: [FooterChip]
    /// The hidden ones that are not calm: the "+n".
    var hiddenNeedingLook: [FooterChip]

    var visible: [FooterChip] { order.filter { shown[$0] != nil } }
}

/// The footer's chips. Every present chip shows, always in one fixed order (Prod, VPN, RAM, limit,
/// PRs, commands) so none swaps places. A calm chip is compact (an icon and its shortest useful
/// value); one that needs a look (news, warning, alert) writes out its current wording. When the
/// measured widths do not fit the row, the chips give up space in this order: the ones needing a
/// look drop their secondary text, the longest first, step by step down to their compact form (which
/// keeps the tone colour); only when every chip is compact and the row still does not fit does the
/// last calm chip go into the menu, then, as a last resort, the last of the others. All pure, so
/// `--chips-selfcheck` checks it.
enum ChipPicker {
    /// Where a chip's tone is not calm: it writes its full wording.
    static func wantsFull(_ tone: ChipTone) -> Bool { tone > .calm }

    /// The row's width: the chips with `spacing` between them, plus the menu's own width (and
    /// one more gap) when something is in it.
    static func width(_ choice: ChipChoice, _ chips: [ChipWidth], spacing: Double, menu: Double) -> Double {
        var parts = choice.visible.compactMap { chip in chips.first { $0.chip == chip }.flatMap { item in choice.shown[chip].map { item.width(at: $0) } } }
        if !choice.hidden.isEmpty { parts.append(menu) }
        return parts.reduce(0, +) + spacing * Double(max(0, parts.count - 1))
    }

    /// Which chips show, in which form, for a row `available` wide. `wide` (the two-column layout)
    /// starts every chip in its full wording; the calm ones are the first to go compact.
    static func fit(_ chips: [ChipWidth], available: Double, spacing: Double, menu: Double, wide: Bool = false) -> ChipChoice {
        let present = FooterChip.order.compactMap { chip in chips.first { $0.chip == chip } }
        let order = present.map(\.chip)
        func choice(_ shown: [FooterChip: Int]) -> ChipChoice {
            let hidden = order.filter { shown[$0] == nil }
            let looks = hidden.filter { chip in present.first { $0.chip == chip }.map { $0.tone > .calm } ?? false }
            return ChipChoice(shown: shown, order: order, hidden: hidden, hiddenNeedingLook: looks)
        }
        func fits(_ c: ChipChoice) -> Bool { width(c, present, spacing: spacing, menu: menu) <= available + 0.5 }

        var shown = Dictionary(uniqueKeysWithValues: present.map { ($0.chip, wide || wantsFull($0.tone) ? 0 : $0.last) })
        var current = choice(shown)
        // 0. Wide: the calm chips go compact first, the last first.
        if wide {
            for item in present.reversed() where !fits(current) && !wantsFull(item.tone) {
                shown[item.chip] = item.last
                current = choice(shown)
            }
        }
        // 1. Chips needing a look drop their secondary text, the longest first (the later one on a tie).
        while !fits(current) {
            let candidates = present.enumerated().filter { wantsFull($0.element.tone) && (shown[$0.element.chip] ?? $0.element.last) < $0.element.last }
            guard let pick = candidates.max(by: { a, b in
                let wa = a.element.width(at: shown[a.element.chip] ?? 0), wb = b.element.width(at: shown[b.element.chip] ?? 0)
                return wa != wb ? wa < wb : a.offset < b.offset
            }) else { break }
            shown[pick.element.chip] = (shown[pick.element.chip] ?? 0) + 1
            current = choice(shown)
        }
        // 2. Only now, with everything compact, the last calm chips go into the menu.
        for item in present.reversed() where !fits(current) && !wantsFull(item.tone) {
            shown[item.chip] = nil
            current = choice(shown)
        }
        // 3. Last resort: the last of the others follow.
        for item in present.reversed() where !fits(current) && shown[item.chip] != nil {
            shown[item.chip] = nil
            current = choice(shown)
        }
        return current
    }

    /// The "+n" after the chips: how many hidden ones need a look.
    static func moreText(_ choice: ChipChoice) -> String? {
        choice.hiddenNeedingLook.isEmpty ? nil : "+\(choice.hiddenNeedingLook.count)"
    }

    /// A limit window's tone: 90% and over is an alert, 70% a warning (where its number turns amber).
    static func limitTone(five: LimitWindow?, week: LimitWindow?) -> ChipTone {
        let top = max(five?.usedPercent ?? 0, week?.usedPercent ?? 0)
        return top >= 90 ? .alert : top >= 70 ? .warning : .calm
    }

    /// Widths like the real chips' (pt): each one's forms, widest first, as the row measures them.
    /// A tone changes the wording, not the forms, except Prod and PRs, whose compact form is wider
    /// while they need a look (the count, the badge) than when calm (the dot, the mark).
    static func sampleWidths(_ tones: [FooterChip: ChipTone] = [:], absent: Set<FooterChip> = []) -> [ChipWidth] {
        func steps(_ chip: FooterChip, _ tone: ChipTone) -> [Double] {
            switch chip {
            case .prod: return tone == .calm ? [46] : [170, 104, 63]
            case .vpn: return tone == .calm ? [66, 24] : [86, 24]
            case .ram: return tone == .calm ? [80, 50] : [171, 87, 53]
            case .limit: return [112, 53]
            case .prs: return tone == .calm ? [40, 26] : [54, 32]
            case .commands: return [37]
            }
        }
        return FooterChip.order.filter { !absent.contains($0) }.map { ChipWidth(chip: $0, tone: tones[$0] ?? .calm, steps: steps($0, tones[$0] ?? .calm)) }
    }

    /// The footer's room for the chips at the notch's width (470 pt), as the row is proposed it.
    static let rowAt470 = 325.0

    static func selfCheck() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1; print("FAIL \(what)") } }
        func all(_ tones: [FooterChip: ChipTone] = [:], absent: Set<FooterChip> = [], snoozedProd: Bool = false) -> [ChipWidth] {
            sampleWidths(snoozedProd ? tones.filter { $0.key != .prod } : tones, absent: absent)
        }
        let roomy = 1000.0, spacing = 8.0, menu = 28.0
        func pick(_ chips: [ChipWidth], _ available: Double = roomy, wide: Bool = false) -> ChipChoice {
            fit(chips, available: available, spacing: spacing, menu: menu, wide: wide)
        }
        func total(_ choice: ChipChoice, _ chips: [ChipWidth]) -> Double { width(choice, chips, spacing: spacing, menu: menu) }
        let order = FooterChip.order
        func last(_ chips: [ChipWidth], _ chip: FooterChip) -> Int { chips.first { $0.chip == chip }?.last ?? 0 }

        // Every present chip shows, in the fixed order, however many need a look.
        let calmChips = all()
        let calm = pick(calmChips)
        expect(calm.visible == order && calm.hidden.isEmpty, "all calm: every chip shows, in the fixed order")
        expect(order.allSatisfy { calm.shown[$0] == last(calmChips, $0) }, "all calm: each compact")
        expect(moreText(calm) == nil, "all calm: no +n")
        let oneChips = all([.ram: .alert])
        let one = pick(oneChips)
        expect(one.visible == order && one.shown[.ram] == 0 && one.shown[.prod] == last(oneChips, .prod), "one alert: only RAM writes itself out, nobody moves")
        let threeChips = all([.prod: .alert, .vpn: .warning, .prs: .news])
        let three = pick(threeChips)
        expect(three.visible == order && [FooterChip.prod, .vpn, .prs].allSatisfy { three.shown[$0] == 0 }
               && [FooterChip.ram, .limit, .commands].allSatisfy { three.shown[$0] == last(threeChips, $0) }, "three need a look: those three are full")

        // Expansion follows the tone: news, warning and alert are full; calm is compact.
        for tone in [ChipTone.news, .warning, .alert] { expect(wantsFull(tone), "\(tone) writes its full wording") }
        expect(!wantsFull(.calm), "calm is compact")
        // Snoozed Prod counts as calm (the input's effective tone).
        let snoozed = pick(all([.prod: .alert], snoozedProd: true))
        expect(snoozed.shown[.prod] == 0 && snoozed.hidden.isEmpty, "snoozed Prod stays as small as a calm one")

        // THE RULE: at 470 pt every combination of tones for today's six chips hides nothing.
        let tones: [ChipTone] = [.calm, .news, .warning, .alert]
        var combinations = 0, hid = 0, worstCompact = 0.0
        var index = [0, 0, 0, 0, 0, 0]
        while true {
            let set = Dictionary(uniqueKeysWithValues: zip(order, index.map { tones[$0] }))
            let chips = all(set)
            let choice = pick(chips, rowAt470)
            combinations += 1
            if !choice.hidden.isEmpty || choice.visible != order { hid += 1 }
            let compactRow = chips.map(\.compact).reduce(0, +) + spacing * Double(chips.count - 1)
            worstCompact = max(worstCompact, compactRow)
            var digit = 0
            while digit < index.count { index[digit] += 1; if index[digit] < tones.count { break }; index[digit] = 0; digit += 1 }
            if digit == index.count { break }
        }
        expect(combinations == 4096, "all 4096 tone combinations were tried")
        expect(hid == 0, "470 pt: no combination of tones hides a chip (\(hid) did)")
        expect(worstCompact <= rowAt470, "470 pt: six compact chips, tones and all, fit the row (\(worstCompact) of \(rowAt470))")

        // Order of giving up space: attention chips shrink, longest first, before anything is hidden.
        let sixChips = all([.prod: .alert, .vpn: .alert, .ram: .alert, .limit: .warning, .prs: .news])
        let six = pick(sixChips, rowAt470)
        expect(six.hidden.isEmpty && total(six, sixChips) <= rowAt470 + 0.5, "all five needing a look at 470 pt: shrunk, none hidden")
        let fullRow = total(pick(sixChips), sixChips)
        var previous = pick(sixChips, fullRow)
        var steps = 0
        var shrinkOk = true
        var room = fullRow
        while room > 0 && steps < 400 {
            room -= 4
            let next = pick(sixChips, room)
            if next.hidden.isEmpty {
                // Nothing is hidden: no chip is wider than before, none moved.
                for chip in order where (next.shown[chip] ?? 0) < (previous.shown[chip] ?? 0) { shrinkOk = false }
            } else {
                // Something is hidden: every chip is already compact, and the hidden one is calm.
                shrinkOk = shrinkOk && next.visible.allSatisfy { next.shown[$0] == last(sixChips, $0) }
                shrinkOk = shrinkOk && next.hidden.allSatisfy { chip in sixChips.first { $0.chip == chip }.map { $0.tone == .calm } ?? false }
                break
            }
            previous = next
            steps += 1
        }
        expect(shrinkOk, "narrowing: chips only shrink, and hiding starts only with every chip compact")
        // The longest goes first: RAM (171) before Prod (170).
        let tight = pick(sixChips, fullRow - 1)
        expect(tight.shown[.ram] == 1 && tight.shown[.prod] == 0, "one point short: the longest (RAM) drops its secondary text first")
        // Prod's ladder is walked a step at a time: "Prod 2 alerting · p95" -> "Prod 2 alerting" -> "Prod 2".
        let prodOnly = all([.prod: .alert], absent: [.vpn, .ram, .limit, .prs, .commands])
        expect(pick(prodOnly, 170).shown[.prod] == 0 && pick(prodOnly, 169).shown[.prod] == 1 && pick(prodOnly, 103).shown[.prod] == 2 && pick(prodOnly, 62).hidden == [.prod],
               "Prod: full, then words, then the count, then the menu")
        // A compact chip that needs a look still takes its (wider) place rather than a calm one's.
        expect(pick(sixChips, rowAt470).shown[.prod] != nil, "Prod keeps its place")
        // Only when everything is compact and the row is still short does the last calm chip go.
        let compactWidth = total(pick(calmChips, 0).hidden.isEmpty ? calm : calm, calmChips)
        expect(pick(calmChips, compactWidth).hidden.isEmpty, "exactly fitting: nothing hidden")
        let narrow = pick(calmChips, compactWidth - 1)
        expect(narrow.hidden == [.commands] || narrow.hidden == [.prs, .commands], "a hair too narrow: the last calm chip goes into the menu (got \(narrow.hidden))")
        expect(narrow.visible == Array(order.prefix(order.count - narrow.hidden.count)), "the visible ones keep their order")
        expect(moreText(narrow) == nil, "calm ones in the menu: a quiet menu, no +n")
        // A chip needing a look is not the one to go while a calm one can.
        let attention = all([.commands: .alert])
        let squeeze = pick(attention, compactWidth - 20)
        expect(squeeze.shown[.commands] != nil && squeeze.hidden.allSatisfy { $0 != .commands }, "an alert outlasts calm chips")
        // Past that, even the chips needing a look follow, the last first.
        let squeezed = pick(sixChips, 120)
        expect(!squeezed.shown.isEmpty && total(squeezed, sixChips) <= 120.5, "alerts all around, little room: hidden to fit")
        expect(squeezed.visible == Array(order.prefix(squeezed.visible.count)), "alerts squeezed: the first in the order stay")
        expect(moreText(squeezed) == "+\(squeezed.hiddenNeedingLook.count)" && !squeezed.hiddenNeedingLook.isEmpty, "alerts in the menu are counted in +n")
        expect(pick(calmChips, 0).visible.isEmpty && pick(calmChips, 0).hidden == order, "no room at all: only the menu")
        // No jumping: the same chips give the same choice, and a chip's widths do not depend on the others.
        expect(pick(sixChips, rowAt470) == pick(sixChips, rowAt470), "the same input gives the same choice")
        expect(all([.ram: .alert]).first { $0.chip == .prod } == all().first { $0.chip == .prod }, "a chip's widths do not depend on the others")

        // Wide: everything in full where it fits; short of that the calm ones go compact first (the last first).
        let wideAll = pick(calmChips, roomy, wide: true)
        expect(order.allSatisfy { wideAll.shown[$0] == 0 }, "wide with room: every chip in full")
        let fullWidth = total(wideAll, calmChips)
        let wideTight = pick(calmChips, fullWidth - 1, wide: true)
        expect(wideTight.hidden.isEmpty && wideTight.shown[.commands] == last(calmChips, .commands) && wideTight.shown[.prod] == 0, "wide, a hair short: the last chip's form gives, the first stays full")
        let wideAttention = all([.prod: .alert, .ram: .alert])
        let wideShort = pick(wideAttention, total(pick(wideAttention, roomy, wide: true), wideAttention) - 60, wide: true)
        expect(wideShort.hidden.isEmpty && wideShort.shown[.ram] == 0, "wide, short: calm ones compact first, the ones needing a look keep their words")
        expect(pick(calmChips, compactWidth, wide: true).hidden.isEmpty, "wide: the compact row always fits where the narrow one does")
        // Unconfigured sources never take a place.
        let missing = pick(all([.vpn: .alert], absent: [.prod, .limit]))
        expect(missing.visible == [.vpn, .ram, .prs, .commands] && missing.hidden.isEmpty, "absent sources are not shown, nor in the menu")
        expect(pick([]).visible.isEmpty && pick([]).hidden.isEmpty, "no chips")
        // Stable widths: a calm chip's width does not depend on the others.
        expect(total(pick(calmChips), calmChips) == compactWidth, "calm row width is the sum of the compact widths")

        // The limit's tone.
        func window(_ used: Double) -> LimitWindow { LimitWindow(usedPercent: used, resetsAt: nil, minutes: nil) }
        expect(limitTone(five: nil, week: nil) == .calm && limitTone(five: window(69), week: window(10)) == .calm, "limit under 70 is calm")
        expect(limitTone(five: window(10), week: window(70)) == .warning, "70 is a warning")
        expect(limitTone(five: window(90), week: window(10)) == .alert && limitTone(five: nil, week: window(100)) == .alert, "90 and over is an alert")

        print("chips selfcheck: \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }

    static func runIfAsked(_ arguments: [String]) {
        guard arguments.contains("--chips-selfcheck") else { return }
        exit(selfCheck())
    }
}
