import AppKit
import Combine
import SwiftUI

/// Where the notch is, and how big: on the built-in display when it has one, else a pill
/// at the top centre of the main display.
struct NotchGeometry {
    var screen: NSRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool
    /// The width of each wing beside the notch, where the collapsed status shows.
    let wing: CGFloat = 46
    /// One column: the agents, with the pipelines under them.
    let expandedWidth: CGFloat = 470
    /// The gap between the two columns.
    static let gutter: CGFloat = 12
    /// Two columns, agents left and pipelines right: two single widths and the gutter, kept
    /// 40 pt from each screen edge.
    var wideWidth: CGFloat { min(expandedWidth * 2 + Self.gutter + 8, screen.width - 80) }
    /// Whether two columns fit side by side at all; else one column even with both sections.
    var canGoWide: Bool { wideWidth >= 2 * 400 + Self.gutter }
    /// The tallest the expanded body may grow below the strip, about half the screen at most;
    /// past it the list scrolls. The window is a fixed transparent box, and its size costs
    /// nothing to draw.
    var maxHeight: CGFloat { min(520, (screen.height / 2).rounded(), screen.height - notchHeight - 60) }

    static func current() -> NotchGeometry {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        if let screen = notched, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                screen: screen.frame,
                notchWidth: screen.frame.width - left.width - right.width,
                notchHeight: screen.safeAreaInsets.top,
                hasNotch: true
            )
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return NotchGeometry(screen: screen.frame, notchWidth: 120, notchHeight: NSStatusBar.system.thickness, hasNotch: false)
    }

    func collapsedWidth(showsWings: Bool) -> CGFloat {
        notchWidth + (showsWings ? wing * 2 : 0)
    }
}

/// A borderless panel above the menu bar that never takes focus from your editor.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    /// Never key: nothing in it takes typing, and a click on it (the pin, Details, a row) must
    /// leave your keystrokes with the app you were typing in. Buttons still take the first
    /// click (see ClickThroughHostingView).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hover for views in the panel. SwiftUI's onHover never fires there: the panel is never key and
/// the app is rarely active. A view names its frame (`.global`, the window's top-left points) as
/// a zone, or a grid of cells; the controller's pointer tick says where the pointer is, and this
/// publishes which zone (the smallest that holds the pointer) or which cell it is over, only when
/// that changes.
@MainActor
final class HoverHub: ObservableObject {
    struct Cell: Equatable {
        var grid: String
        var column: Int
        var row: Int
    }

    var zones: [String: CGRect] = [:]
    /// A grid's frame and its pitch (a cell and the gap after it).
    var grids: [String: (frame: CGRect, pitch: CGFloat)] = [:]
    @Published private(set) var hovered: String?
    @Published private(set) var cell: Cell?

    func update(_ point: CGPoint?) {
        var over: String?
        var overCell: Cell?
        if let point {
            over = zones.filter { $0.value.contains(point) }.min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
            for (name, grid) in grids where grid.frame.contains(point) && grid.pitch > 0 {
                overCell = Cell(grid: name, column: Int((point.x - grid.frame.minX) / grid.pitch), row: Int((point.y - grid.frame.minY) / grid.pitch))
            }
        }
        if over != hovered { hovered = over }
        if overCell != cell { cell = overCell }
    }
}

private struct HoverHubKey: EnvironmentKey {
    static let defaultValue: HoverHub? = nil
}

extension EnvironmentValues {
    /// The notch's hover tracking; nil outside the notch (onHover works there).
    var hoverHub: HoverHub? {
        get { self[HoverHubKey.self] }
        set { self[HoverHubKey.self] = newValue }
    }
}

/// Gives `content` whether the pointer is over it, through the hub, and keeps its zone current.
struct HoverZone<Content: View>: View {
    @ObservedObject var hub: HoverHub
    let key: String
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(hub.hovered == key)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { hub.zones[key] = $0 }
            .onDisappear { hub.zones[key] = nil }
    }
}

/// A hosting view that takes the first click, so a row answers without a focusing click first.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel. The window never moves or resizes: it is a fixed, transparent box under the
/// notch that lets every click through except over the black shape, and SwiftUI alone animates
/// the shape between hugging the notch and the dropped-down session list.
@MainActor
final class NotchController: ObservableObject {
    @Published private(set) var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            // Whoever opens it says first whether the pointer is over it (`isLooking`).
            if isExpanded {
                store.panelOpened()
                builds.panelOpened(looking: isLooking)
                reviews.panelOpened()
            } else {
                isLooking = false
                revealHold = nil
                builds.panelClosed()
            }
            machine.setPanelOpen(isExpanded && openPanel == Self.machinePanel)
            vpn.setPanelOpen(isExpanded && openPanel == Self.vpnPanel)
            CommandsStore.shared.setPanelOpen(isExpanded && openPanel == Self.commandsPanel)
        }
    }
    /// Which full-width panel is open under the header: Usage, Code, Board, Machine, VPN or PRs, one at a time.
    @Published var openPanel: String? {
        didSet {
            machine.setPanelOpen(isExpanded && openPanel == Self.machinePanel)
            vpn.setPanelOpen(isExpanded && openPanel == Self.vpnPanel)
            CommandsStore.shared.setPanelOpen(isExpanded && openPanel == Self.commandsPanel)
        }
    }
    static let machinePanel = "Machine"
    static let commandsPanel = "Commands"
    static let vpnPanel = "VPN"
    static let pullRequestsPanel = "PRs"
    static let boardPanel = "Board"
    @Published private(set) var geometry = NotchGeometry.current()
    /// Pinned open: the notch stays expanded until unpinned, and no click or pointer leaving
    /// collapses it. Remembered across restarts.
    @Published private(set) var isPinned = UserDefaults.standard.bool(forKey: NotchController.pinnedKey)
    /// The shape's size as the view laid it out; zero until its first layout.
    var shapeSize: CGSize = .zero
    /// Prod's banner, in the window's top-left points while it shows (else zero): collapsed, it
    /// hangs below the shape and takes clicks there without opening the notch.
    var headsUpRect: CGRect = .zero
    /// Hover for the views in the panel (see HoverHub): SwiftUI's onHover never fires there.
    let hover = HoverHub()
    /// The pointer near the closed notch, for the effects' glow.
    let pointer = PointerFeed()

    private static let pinnedKey = "notch.pinned"
    private let store: SessionStore
    private let builds: BuildStore
    private let prod: ProdStore
    private let machine: MachineStore
    private let vpn: VPNStore
    let reviews: ReviewStore
    /// A notification's Open showed the Machine panel: it stays open, as if pinned, until the
    /// pointer has been over it and left, or 20 seconds pass untouched.
    private var revealHold: Date?
    /// `--preview`: always expanded, in the middle of the screen, for a look without hovering;
    /// `--preview --collapsed`: the collapsed strip there instead; `--preview --hover`: there,
    /// but opening on hover and closing (or staying pinned) as the real notch does.
    private let isPreview = CommandLine.arguments.contains("--preview")
    private let isCollapsedPreview = CommandLine.arguments.contains("--preview") && CommandLine.arguments.contains("--collapsed")
    private let isHoverPreview = CommandLine.arguments.contains("--preview") && CommandLine.arguments.contains("--hover")
    /// Always expanded and never tracking the pointer: the still preview.
    private var isStill: Bool { isPreview && !isHoverPreview }
    /// Expanded with the pointer over it. Pinned with the pointer away, the notch stays open but
    /// nothing on show counts as looked at (a failed run stays unseen), as when it is closed.
    private var isLooking = false {
        didSet {
            guard isLooking != oldValue else { return }
            prod.setLooking(isLooking)
            reviews.setLooking(isLooking)
        }
    }
    /// A full-screen window fills the notch's screen: pinned gives way to hover until it leaves.
    private var fullScreenAhead = false
    private let panel = NotchPanel()
    private var collapseWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var watchers: Set<AnyCancellable> = []

    init(store: SessionStore, builds: BuildStore, prod: ProdStore, machine: MachineStore, vpn: VPNStore, reviews: ReviewStore) {
        self.store = store
        self.builds = builds
        self.prod = prod
        self.machine = machine
        self.vpn = vpn
        self.reviews = reviews
        panel.contentView = ClickThroughHostingView(rootView: ProdHeadsUpHost(prod: prod, controller: self,
                                                                              content: RootView(store: store, builds: builds, prod: prod, machine: machine, vpn: vpn,
                                                                                               reviews: reviews, controller: self))
            .environment(\.hoverHub, hover))
        // Prod's banner gives way to a full-screen app (notification only).
        prod.popBlocker = { [weak self] in self?.fullScreenWindowAhead() == true ? "full screen" : nil }
        machine.reveal = { [weak self] in self?.reveal(panel: Self.machinePanel) }
        vpn.reveal = { [weak self] in self?.reveal(panel: Self.vpnPanel) }
        if isStill && !isCollapsedPreview {
            isExpanded = true
            isLooking = true
            store.panelOpened()
            builds.panelOpened()
            prod.setLooking(true)
            reviews.panelOpened()
            reviews.setLooking(true)
            // `--preview --board`: the Board open, for a look.
            if CommandLine.arguments.contains("--board") { openPanel = Self.boardPanel }
        }
        placeWindow()
        panel.orderFrontRegardless()

        // Mouse moves outside our window reach the global monitor, those over it the local one.
        let track: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.trackPointer() } }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            track(event)
            return event
        } as Any)
        // And a slow tick for a shape that changed under a pointer standing still.
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                geometry = NotchGeometry.current()
                placeWindow()
            }
            .store(in: &watchers)

        // Entering or leaving a full-screen space, or another app coming forward there.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in self?.checkFullScreenSoon() }
                .store(in: &watchers)
        }
        checkFullScreen()
    }

    var showsWings: Bool {
        !store.sessions.isEmpty || !geometry.hasNotch || builds.hasActive || builds.hasUnseenFailure
            || prod.hasOpenAlert || prod.hasUnseenAlert || machine.showsDot || machine.showsSlot || vpn.showsSlot || reviews.unseenCount > 0
    }

    /// Pinned and nothing full-screen in the way: the notch stays expanded. Also for a while after
    /// a notification's Open showed a panel.
    private var holdsOpen: Bool {
        if let revealHold, revealHold > Date() { return !isStill }
        return isPinned && !fullScreenAhead && !isStill
    }

    /// Opens the notch on `panel` (a notification's Open), held open until the pointer has been
    /// over it and left, or 20 seconds.
    func reveal(panel: String) {
        openPanel = panel
        guard !isStill else { return }
        revealHold = Date().addingTimeInterval(20)
        if !isExpanded {
            isLooking = false
            isExpanded = true
        }
    }

    /// ⌃⌥Space: opens the notch (held open like a notification's Open), or closes it, pinned or not.
    func toggleFromKeyboard() {
        if isExpanded {
            revealHold = nil
            collapseWork?.cancel()
            collapseWork = nil
            if !isStill { isExpanded = false }
        } else {
            guard !isStill else { return }
            revealHold = Date().addingTimeInterval(20)
            isLooking = false
            isExpanded = true
        }
    }

    /// Collapses at once, after a click sent you somewhere else; pinned, it stays open.
    func collapse() {
        guard !isStill, !holdsOpen else { return }
        collapseWork?.cancel()
        collapseWork = nil
        isExpanded = false
    }

    /// The pin in the header: pinned, the notch stays open; unpinned, it closes once the pointer
    /// leaves, as before.
    func togglePin() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey)
        if isPinned { checkFullScreen() }
    }

    /// The space change lands before the full-screen window settles: look now and once more.
    private func checkFullScreenSoon() {
        guard isPinned else { return }
        checkFullScreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkFullScreen() }
    }

    /// Whether another app's full-screen window is on the notch's screen now: a window as wide as
    /// the screen that reaches its bottom edge and starts at its top or just under the notch
    /// (where macOS puts a full-screen window on a notched display: 0,39 1800×1130 on a
    /// 1800×1169 one). A zoomed window stops above the Dock and under the menu bar. Read only
    /// while pinned: unpinned, the notch opens only on hover anyway.
    private func checkFullScreen() {
        guard isPinned, !isStill else {
            fullScreenAhead = false
            return
        }
        fullScreenAhead = fullScreenWindowAhead()
    }

    /// The same look, pinned or not (Prod's banner asks it too).
    func fullScreenWindowAhead() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self.fullScreenAhead(windows: windows, screen: geometry.screen, primary: NSScreen.screens.first?.frame ?? geometry.screen,
                                    underNotch: geometry.hasNotch ? geometry.notchHeight : 0, me: getpid())
    }

    /// The test on a window list (CGWindowListCopyWindowInfo's dictionaries), pure for the self-check.
    nonisolated static func fullScreenAhead(windows: [[String: Any]], screen: NSRect, primary: NSRect, underNotch: CGFloat, me: pid_t) -> Bool {
        // Window bounds are top-left based, from the primary display's top.
        let top = primary.maxY - screen.maxY
        let bottom = top + screen.height
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) != me }) ?? false,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            let spansWidth = abs(rect.minX - screen.minX) < 1 && abs(rect.width - screen.width) < 1
            let reachesBottom = abs(rect.maxY - bottom) < 1
            let startsAtTop = abs(rect.minY - top) < 1 || (underNotch > 0 && rect.minY >= top + underNotch - 1 && rect.minY <= top + underNotch + 2)
            return spansWidth && reachesBottom && startsAtTop
        }
    }

    /// Where the pointer is in the window's top-left points, while the notch is open.
    private func trackHover() {
        guard isExpanded else {
            hover.update(nil)
            return
        }
        let point = NSEvent.mouseLocation
        let frame = panel.frame
        hover.update(CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
    }

    private func placeWindow() {
        let g = geometry
        let width = max(g.wideWidth, g.expandedWidth, g.collapsedWidth(showsWings: true)) + 40
        let height = g.notchHeight + g.maxHeight
        let top = isPreview ? g.screen.midY + 300 : g.screen.maxY
        panel.setFrame(NSRect(x: g.screen.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    /// The shape on screen, in AppKit's bottom-left coordinates: it hangs from the window's top centre.
    private var shapeOnScreen: NSRect {
        let window = panel.frame
        var size = shapeSize
        if size == .zero { size = CGSize(width: geometry.collapsedWidth(showsWings: showsWings), height: geometry.notchHeight) }
        return NSRect(x: window.midX - size.width / 2, y: window.maxY - size.height, width: size.width, height: size.height)
    }

    private func trackPointer() {
        trackHover()
        // Prod's banner: the pointer on it keeps it up. Collapsed, it lies outside the shape, so
        // it takes clicks there itself and does not open the notch.
        if prod.headsUp != nil, headsUpRect != .zero {
            let point = NSEvent.mouseLocation, frame = panel.frame
            let over = headsUpRect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y))
            prod.setHeadsUpHovered(over)
            if over, !isExpanded {
                if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
                return
            }
        }
        guard !isStill else {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let point = NSEvent.mouseLocation
        pointer.update(pointer: point, shape: shapeOnScreen, active: !isExpanded && EffectsPrefs.shared.pointerGlow)
        // A little slop, and up to the very top edge, so the screen's edge counts as the notch.
        var zone = shapeOnScreen.insetBy(dx: -6, dy: -6)
        zone.size.height += 6
        let isInside = zone.contains(point)
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write("pointer \(point) shapeSize \(shapeSize) zone \(zone) window \(panel.frame) inside \(isInside) expanded \(isExpanded) pinned \(isPinned) looking \(isLooking) fullScreen \(fullScreenAhead) key \(panel.isKeyWindow)\n".data(using: .utf8)!)
        }
        // Each change is a call to the window server; the tick runs 12 times a second.
        if panel.ignoresMouseEvents == isInside { panel.ignoresMouseEvents = !isInside }

        if isInside {
            collapseWork?.cancel()
            collapseWork = nil
            // Shown by a notification and now looked at: from here it closes as usual.
            if revealHold != nil { revealHold = Date().addingTimeInterval(-1) }
            if !isExpanded {
                isLooking = true
                isExpanded = true
            } else if !isLooking {
                // Pinned, the pointer is back: as if it had just opened.
                isLooking = true
                store.panelOpened()
                builds.panelOpened()
                reviews.panelOpened()
            }
        } else if holdsOpen {
            collapseWork?.cancel()
            collapseWork = nil
            if !isExpanded {
                // Pinned at launch, or a full-screen window just left: open, nobody looking yet.
                isLooking = false
                isExpanded = true
            } else if isLooking {
                isLooking = false
                builds.lookedAway()
            }
        } else if isExpanded, collapseWork == nil {
            // A short grace, so a pointer that slips off the edge does not snap it shut.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.collapseWork = nil
                    self?.isExpanded = false
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}
