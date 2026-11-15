import AppKit
import DictationCore
import QuartzCore
import SwiftUI

/// What the pill shows.
enum DictationPhase: Equatable {
    case idle
    case listening(since: Date)
    case downloading
    case transcribing
    case cleaning
    case inserted
    case copied
    case message(String)
}

/// The waveform: bars whose height follows the microphone level. Each bar is a fixed layer
/// scaled in Y by its own level (a transform, not a redraw), pushed at about 20 Hz from the audio
/// level, so there is no looping animation here.
final class WaveView: NSView {
    static let bars = 9
    private var layers: [CALayer] = []
    private var levels = [Float](repeating: 0, count: WaveView.bars)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<Self.bars {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            layer?.addSublayer(bar)
            layers.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let gap: CGFloat = 2.5
        let width = max(1, (bounds.width - gap * CGFloat(Self.bars - 1)) / CGFloat(Self.bars))
        for (i, bar) in layers.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (width + gap) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
        apply()
    }

    /// A new level (0…1): the bars shift left and the newest enters on the right.
    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        apply()
    }

    func clear() {
        levels = [Float](repeating: 0, count: Self.bars)
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.06)
        for (i, bar) in layers.enumerated() {
            let scale = max(0.14, CGFloat(levels[i]))
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }
}

struct WaveformView: NSViewRepresentable {
    let hub: DictationPillModel
    func makeNSView(context: Context) -> WaveView {
        let view = WaveView()
        hub.wave = view
        return view
    }
    func updateNSView(_ view: WaveView, context: Context) { hub.wave = view }
}

@MainActor
final class DictationPillModel: ObservableObject {
    @Published var phase: DictationPhase = .idle
    weak var wave: WaveView?
    /// The words heard so far while listening: settled text and the tail still changing.
    @Published var caption = LiveText.Caption.empty
    /// A line under the pill while listening (typing stopped), never the words themselves.
    @Published var notice: String?
    func push(level: Float) { wave?.push(level) }

    func setCaption(final: String, volatile: String, limit: Int) {
        let next = LiveText.caption(final: final, volatile: volatile, limit: limit)
        if next != caption { caption = next }
    }

    func resetLive() {
        caption = LiveText.Caption.empty
        notice = nil
    }
}

struct DictationPillView: View {
    @ObservedObject var model: DictationPillModel
    var geometry: NotchGeometry
    static let wing: CGFloat = 132
    /// Room under the notch row for two lines of words; the window is this much taller, the
    /// width is unchanged.
    static let captionHeight: CGFloat = 34
    static let captionPadding: CGFloat = 14

    /// How many characters of caption fit on its two lines, with room to spare.
    static func captionLimit(notchWidth: CGFloat) -> Int {
        let width = notchWidth + wing * 2 - captionPadding * 2
        return max(20, Int(width / 7) * 2 - 8)
    }

    private var showsCaption: Bool {
        guard case .listening = model.phase else { return false }
        return model.notice != nil || !model.caption.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                left.frame(width: Self.wing, alignment: .leading)
                Color.clear.frame(width: geometry.notchWidth)
                right.frame(width: Self.wing, alignment: .trailing)
            }
            .frame(height: geometry.notchHeight)
            if showsCaption {
                captionRow
                    .padding(.horizontal, Self.captionPadding)
                    .frame(height: Self.captionHeight, alignment: .top)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsCaption)
        .background(Color.black)
        .clipShape(NotchShape(radius: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var left: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .listening:
                LoopLayer(kind: .dot, color: Strip.failed.nsColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Recording")
                WaveformView(hub: model).frame(width: 44, height: 14)
            case .downloading, .transcribing, .cleaning:
                Spinner(color: NSColor.white.withAlphaComponent(0.85), size: 11)
            case .inserted, .copied:
                Image(systemName: "checkmark.circle.fill").font(Typo.subtitle(.semibold)).foregroundStyle(Strip.done)
            case .message:
                Image(systemName: "exclamationmark.triangle.fill").font(Typo.subtitle(.semibold)).foregroundStyle(Strip.waiting)
            case .idle:
                EmptyView()
            }
        }
        .padding(.leading, 14)
    }

    @ViewBuilder private var right: some View {
        Group {
            switch model.phase {
            case .listening(let since):
                Text(since, style: .timer).font(Typo.body(.medium, digits: true)).foregroundStyle(Strip.ink)
            case .downloading: label("Downloading")
            case .transcribing: label("Transcribing")
            case .cleaning: label("Cleaning up")
            case .inserted: label("Inserted")
            case .copied: label("Copied, paste")
            case .message(let text): label(text)
            case .idle: EmptyView()
            }
        }
        .padding(.trailing, 14)
    }

    @ViewBuilder private var captionRow: some View {
        if let notice = model.notice {
            Text(notice).font(Typo.subtitle(.medium)).foregroundColor(Strip.waiting).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let c = model.caption
            let lead = c.cut ? "…" : ""
            let gap = (c.final.isEmpty || c.volatile.isEmpty) ? "" : " "
            (Text(lead + c.final).foregroundColor(Strip.ink) + Text(gap + c.volatile).foregroundColor(Strip.ink.opacity(0.5)))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Typo.body(.medium)).foregroundStyle(Strip.ink).lineLimit(1).minimumScaleFactor(0.75)
    }
}

private extension Color {
    var nsColor: NSColor { NSColor(self) }
}

/// A borderless, click-through panel on the notch: black wings either side of it while
/// dictating, above the notch's own window.
@MainActor
final class DictationPill {
    let model = DictationPillModel()
    private let panel: NotchPanel
    private var hideWork: DispatchWorkItem?
    private var geometry = NotchGeometry.current()

    init() {
        panel = NotchPanel()
        panel.level = .aboveNotch
        panel.alphaValue = 0
    }

    /// Shows `phase`; a result (inserted, a message) goes away by itself after `autoHide` seconds.
    func show(_ phase: DictationPhase, autoHide: TimeInterval? = nil) {
        hideWork?.cancel()
        if phase == .idle { hide(); return }
        if panel.alphaValue == 0 || panel.contentView == nil { place() }
        if case .listening = phase {} else { model.notice = nil }
        model.phase = phase
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        model.phase = .idle
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.model.phase == .idle { self?.panel.orderOut(nil) } }
        })
    }

    /// A window the width of the notch and both wings, flush with the top of the notch's screen.
    private func place() {
        geometry = NotchGeometry.current()
        let width = geometry.notchWidth + DictationPillView.wing * 2
        let height = geometry.notchHeight + DictationPillView.captionHeight
        let frame = NSRect(x: geometry.screen.midX - width / 2, y: geometry.screen.maxY - height, width: width, height: height)
        panel.contentView = NSHostingView(rootView: DictationPillView(model: model, geometry: geometry))
        panel.setFrame(frame, display: true)
    }
}
