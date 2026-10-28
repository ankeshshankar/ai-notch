import AppKit
import SwiftUI

/// The open notch's fill. Black in every theme: it is the hardware notch, grown. With Glass on
/// (Setup → Effects) only the strip on the notch stays black; the body below is frosted glass the
/// desktop shows through, with a short fade from the black so the two meet softly.
struct NotchFill: View {
    var glass: Bool
    var stripHeight: CGFloat
    var radius: CGFloat

    var body: some View {
        if glass {
            VStack(spacing: 0) {
                Color.black.frame(height: stripHeight)
                GlassFill(shape: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 10)
                            .allowsHitTesting(false)
                    }
            }
        } else {
            Color.black
        }
    }
}

/// Frosted glass in a shape: Liquid Glass on macOS 26; on earlier versions the menu's blur of what
/// is behind the window. A light dimming layer sits under it (not over it, so the glass keeps its
/// edge highlights and lensing, and the system's Clear or Tinted choice still shows) for small text.
struct GlassFill<S: Shape>: View {
    var shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let more = contrast == .increased
        let tint = more ? GlassPalette.tintContrast : Palette.glassTint
        let dim = more ? GlassPalette.dimContrast : GlassPalette.dim
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(tint), in: shape)
                .background(shape.fill(dim))
        } else {
            BehindWindowBlur().clipShape(shape).overlay(shape.fill(dim))
        }
        #else
        BehindWindowBlur().clipShape(shape).overlay(shape.fill(dim))
        #endif
    }
}

/// A card that floats above the rows (a hover card, the Prod banner). With Glass on (macOS 26) it is
/// its own regular glass, a separate layer above the body, not an opaque sheet. Otherwise, and on
/// earlier macOS or with Increase Contrast, it keeps the solid card over the body's surface so the
/// rows under it do not show through.
struct FloatingCard: ViewModifier {
    var radius: CGFloat
    /// A colour wash over the card, like the Prod banner's red; the plain card colour needs none on glass.
    var wash: Color = Palette.card
    @Environment(\.notchGlass) private var glass

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *), glass.isOn, !glass.highContrast {
            content
                .background(shape.fill(wash == Palette.card ? Color.clear : glass.color(wash)))
                .background(Color.clear.glassEffect(.regular, in: shape))
        } else {
            solid(content, shape)
        }
        #else
        solid(content, shape)
        #endif
    }

    private func solid(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(shape.fill(glass.color(wash)))
            .background(shape.fill(glass.isOn && !glass.highContrast ? GlassPalette.backing : Palette.surface))
    }
}

/// How the cards and panels inside the open notch are drawn. With Glass on, the body is the one
/// glass surface; rows and panels on it turn into a thin see-through fill, and floating
/// cards (hover cards, the Prod banner) are glass of their own, a layer above. Off (the default, collapsed, or Reduce Transparency on), every colour is
/// the solid one.
struct GlassLook: Equatable {
    var isOn = false
    /// Increase Contrast is on: stronger fills and edges.
    var highContrast = false

    /// The colour to draw for a solid token: itself when Glass is off, its see-through sibling when on.
    func color(_ token: Color) -> Color {
        isOn ? GlassPalette.sibling(of: token, highContrast: highContrast) : token
    }
}

extension EnvironmentValues {
    /// The one switch the views read to follow the glass look.
    @Entry var notchGlass = GlassLook.off
}

extension GlassLook {
    static let off = GlassLook()
}

/// Sets the glass look for everything inside the notch's window: on only while Glass is switched
/// on in Setup, the notch is open, and Reduce Transparency is off (the tints are not system glass
/// and would not frost by themselves, so that setting keeps the solid look).
struct GlassScope: ViewModifier {
    @ObservedObject var controller: NotchController
    @ObservedObject private var effects = EffectsPrefs.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(\.notchGlass, GlassLook(isOn: effects.glass && controller.isExpanded && !reduceTransparency,
                                                    highContrast: contrast == .increased))
    }
}

/// The see-through fills the cards, panels and edges take with Glass on, light and dark. Values
/// that already let the glass show through (chips, tracks, hovers, the inks) are not here.
enum GlassPalette {
    static let tintContrast = adaptive(light: gray(1.0, 0.50), dark: gray(0.0, 0.50))
    /// The dimming under the body's glass, so small text keeps its contrast over any wallpaper.
    static let dim = adaptive(light: gray(1.0, 0.40), dark: gray(0.0, 0.68))
    static let dimContrast = adaptive(light: gray(1.0, 0.60), dark: gray(0.0, 0.65))

    private static let card = adaptive(light: gray(1.0, 0.40), dark: gray(1.0, 0.05))
    private static let cardContrast = adaptive(light: gray(1.0, 0.70), dark: gray(1.0, 0.08))
    private static let panel = adaptive(light: gray(1.0, 0.30), dark: gray(1.0, 0.04))
    private static let panelContrast = adaptive(light: gray(1.0, 0.60), dark: gray(1.0, 0.06))
    private static let hairline = adaptive(light: gray(0.0, 0.07), dark: gray(1.0, 0.08))
    private static let hairlineContrast = adaptive(light: gray(0.0, 0.35), dark: gray(1.0, 0.40))
    private static let waitingTint = adaptive(light: rgb(0.96, 0.65, 0.14, 0.22), dark: rgb(0.96, 0.65, 0.14, 0.16))
    private static let waitingTintContrast = adaptive(light: rgb(0.96, 0.65, 0.14, 0.30), dark: rgb(0.96, 0.65, 0.14, 0.24))
    private static let failedTint = adaptive(light: rgb(0.86, 0.20, 0.16, 0.14), dark: rgb(1.0, 0.23, 0.19, 0.13))
    private static let failedTintContrast = adaptive(light: rgb(0.86, 0.20, 0.16, 0.22), dark: rgb(1.0, 0.23, 0.19, 0.20))
    private static let approvalCard = adaptive(light: gray(1.0, 0.60), dark: gray(0.0, 0.30))
    private static let approvalCardContrast = adaptive(light: gray(1.0, 0.85), dark: gray(0.0, 0.50))
    /// What a floating card sits on where it cannot be glass of its own: nearly opaque.
    static let backing = adaptive(light: gray(1.0, 0.99), dark: gray(0.12, 0.99))

    /// The see-through sibling of a solid token, found by identity; any other colour is returned as it is.
    static func sibling(of token: Color, highContrast hc: Bool) -> Color {
        switch token {
        case Palette.card: hc ? cardContrast : card
        case Palette.panel: hc ? panelContrast : panel
        case Palette.hairline: hc ? hairlineContrast : hairline
        case Palette.waitingTint: hc ? waitingTintContrast : waitingTint
        case Palette.failedTint: hc ? failedTintContrast : failedTint
        case Palette.approvalCard: hc ? approvalCardContrast : approvalCard
        // An opaque ring would show as a disc on a see-through row.
        case Palette.badgeRing, Palette.badgeRingWaiting: .clear
        default: token
        }
    }
}

/// A panel's card: the fill and hairline edge the Usage, Code, Board, Machine, VPN, Commands and
/// PRs panels share.
struct PanelCard: ViewModifier {
    @Environment(\.notchGlass) private var glass

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(glass.color(Palette.panel)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(glass.color(Palette.hairline), lineWidth: 1))
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
    func floatingCard(radius: CGFloat, wash: Color = Palette.card) -> some View { modifier(FloatingCard(radius: radius, wash: wash)) }
}

/// A blur of whatever is behind the window. Kept active, since the panel is never the key window
/// and an inactive one would turn flat grey.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
