import Foundation
import NotchCore

// The footer's status chips: at most two at once. Which two is one pure function, so it can be
// checked on made-up inputs (`AINotch --chips-selfcheck`). Everything a hidden chip shows or does
// stays reachable: the "+n" / "…" menu lists the hidden ones, each opening its own section.

/// A status source with a chip.
enum FooterChip: String, CaseIterable {
    case prod, vpn, ram, limit, prs, commands

    /// Where a tie between two chips of the same tone goes, and the order the shown ones keep.
    static let order: [FooterChip] = [.prod, .vpn, .ram, .limit, .prs, .commands]
    /// What fills a free place when fewer than two chips are in a non-OK state: Prod, then the limit.
    static let fill: [FooterChip] = [.prod, .limit]

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

struct ChipChoice: Equatable {
    /// At most two, in the fixed order.
    var shown: [FooterChip]
    /// The other present ones, in the fixed order.
    var hidden: [FooterChip]
    /// The hidden ones that are not calm: the "+n".
    var hiddenNeedingLook: [FooterChip]
}

enum ChipPicker {
    static let places = 2

    static func pick(_ inputs: [ChipInput]) -> ChipChoice {
        let present = inputs.filter(\.present)
        func rank(_ chip: FooterChip) -> Int { FooterChip.order.firstIndex(of: chip) ?? Int.max }
        // Non-OK first: alert, warning, news; within a tone, the fixed order.
        let needing = present.filter { $0.effectiveTone > .calm }
            .sorted { ($0.effectiveTone, -rank($0.chip)) > ($1.effectiveTone, -rank($1.chip)) }
        var chosen = needing.prefix(places).map(\.chip)
        for chip in FooterChip.fill where chosen.count < places {
            if present.contains(where: { $0.chip == chip }), !chosen.contains(chip) { chosen.append(chip) }
        }
        let shown = FooterChip.order.filter { chosen.contains($0) }
        let hidden = FooterChip.order.filter { chip in present.contains { $0.chip == chip } && !shown.contains(chip) }
        let looks = hidden.filter { chip in present.first { $0.chip == chip }?.effectiveTone ?? .calm > .calm }
        return ChipChoice(shown: shown, hidden: hidden, hiddenNeedingLook: looks)
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

    static func selfCheck() -> Int32 {
        var failures = 0, checks = 0
        func expect(_ ok: Bool, _ what: String) { checks += 1; if !ok { failures += 1; print("FAIL \(what)") } }
        func input(_ chip: FooterChip, _ tone: ChipTone = .calm, present: Bool = true, snoozed: Bool = false) -> ChipInput {
            ChipInput(chip: chip, present: present, tone: tone, snoozed: snoozed)
        }
        func all(_ tones: [FooterChip: ChipTone] = [:], snoozedProd: Bool = false, absent: Set<FooterChip> = []) -> [ChipInput] {
            FooterChip.allCases.map { input($0, tones[$0] ?? .calm, present: !absent.contains($0), snoozed: $0 == .prod && snoozedProd) }
        }

        // All calm: Prod and the limit, the rest behind the menu without a "+n".
        let calm = pick(all())
        expect(calm.shown == [.prod, .limit], "calm shows Prod and the limit")
        expect(calm.hidden == [.vpn, .ram, .prs, .commands], "calm hides the rest, in order")
        expect(moreText(calm) == nil, "calm has no +n")

        // One alert: it and Prod.
        let ram = pick(all([.ram: .alert]))
        expect(ram.shown == [.prod, .ram], "one alert: Prod fills the other place")
        expect(moreText(ram) == nil && ram.hidden.contains(.limit), "one alert: the limit hides, no +n")
        let limit = pick(all([.limit: .alert]))
        expect(limit.shown == [.prod, .limit], "an alert on the limit with Prod filling")
        let vpn = pick(all([.vpn: .alert]))
        expect(vpn.shown == [.prod, .vpn], "VPN dropped with Prod")

        // Prod alerts: Prod, and nothing needs to fill.
        let prod = pick(all([.prod: .alert]))
        expect(prod.shown == [.prod, .limit], "Prod alert with the limit filling")

        // Three alerts: the top two by the fixed order; the third is the +1.
        let three = pick(all([.prod: .alert, .vpn: .alert, .ram: .alert]))
        expect(three.shown == [.prod, .vpn], "three alerts: the top two by order")
        expect(three.hiddenNeedingLook == [.ram] && moreText(three) == "+1", "three alerts: +1 names RAM")
        let mix = pick(all([.prod: .warning, .ram: .alert, .vpn: .alert, .prs: .news]))
        expect(mix.shown == [.vpn, .ram], "alerts before a warning and news")
        expect(mix.hiddenNeedingLook == [.prod, .prs] && moreText(mix) == "+2", "the warning and the news are the +2")

        // Tone order: alert, then warning, then news; then the fixed order.
        let tones = pick(all([.prs: .news, .limit: .warning, .commands: .news]))
        expect(tones.shown == [.limit, .prs], "warning before news; news ties by order")
        let news = pick(all([.prs: .news]))
        expect(news.shown == [.prod, .prs] && news.hidden.contains(.limit), "news with Prod filling")

        // Snoozed Prod counts as calm: it only fills.
        let snoozedFill = pick(all([.prod: .alert], snoozedProd: true))
        expect(snoozedFill.shown == [.prod, .limit], "snoozed Prod fills like a calm one")
        let snoozedOut = pick(all([.prod: .alert, .ram: .alert, .vpn: .warning], snoozedProd: true))
        expect(snoozedOut.shown == [.vpn, .ram] && snoozedOut.hidden.contains(.prod) && snoozedOut.hiddenNeedingLook.isEmpty,
               "snoozed Prod yields to the alerts and is not counted in +n")

        // Unconfigured sources never take a place.
        let noProd = pick(all([.ram: .alert], absent: [.prod]))
        expect(noProd.shown == [.ram, .limit], "no Prod: the limit fills")
        let nothing = pick(all(absent: [.prod, .limit]))
        expect(nothing.shown.isEmpty && nothing.hidden == [.vpn, .ram, .prs, .commands], "no Prod, no limit: nothing shows, the rest wait in the menu")
        let absentAlert = pick(all([.vpn: .alert, .ram: .alert], absent: [.vpn]))
        expect(absentAlert.shown == [.prod, .ram] && !absentAlert.hidden.contains(.vpn), "an unconfigured source in an alert state is ignored")
        expect(pick([]).shown.isEmpty && pick([]).hidden.isEmpty, "no inputs")
        expect(pick(all()).shown.count <= ChipPicker.places, "never more than two")

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
