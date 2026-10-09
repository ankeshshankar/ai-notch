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
    let expandedWidth: CGFloat = 470
    /// The tallest the expanded list may grow: room for a few rows with approval cards. The
    /// window is a fixed transparent box, and its size costs nothing to draw.
    var maxHeight: CGFloat { min(900, screen.height - notchHeight - 60) }

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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    @Published private(set) var isExpanded = false
    @Published private(set) var geometry = NotchGeometry.current()
    /// The shape's size as the view laid it out; zero until its first layout.
    var shapeSize: CGSize = .zero

    private let store: SessionStore
    /// `--preview`: always expanded, in the middle of the screen, for a look without hovering.
    private let isPreview = CommandLine.arguments.contains("--preview")
    private let panel = NotchPanel()
    private var collapseWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var watchers: Set<AnyCancellable> = []

    init(store: SessionStore) {
        self.store = store
        panel.contentView = ClickThroughHostingView(rootView: RootView(store: store, controller: self))
        if isPreview {
            isExpanded = true
            store.panelOpened()
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
    }

    var showsWings: Bool { !store.sessions.isEmpty || !geometry.hasNotch }

    /// Collapses at once, after a click sent you somewhere else.
    func collapse() {
        guard !isPreview else { return }
        collapseWork?.cancel()
        collapseWork = nil
        isExpanded = false
    }

    private func placeWindow() {
        let g = geometry
        let width = max(g.expandedWidth, g.collapsedWidth(showsWings: true)) + 40
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
        guard !isPreview else {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        let point = NSEvent.mouseLocation
        // A little slop, and up to the very top edge, so the screen's edge counts as the notch.
        var zone = shapeOnScreen.insetBy(dx: -6, dy: -6)
        zone.size.height += 6
        let isInside = zone.contains(point)
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write("pointer \(point) shapeSize \(shapeSize) zone \(zone) window \(panel.frame) inside \(isInside)\n".data(using: .utf8)!)
        }
        // Each change is a call to the window server; the tick runs 12 times a second.
        if panel.ignoresMouseEvents == isInside { panel.ignoresMouseEvents = !isInside }

        if isInside {
            collapseWork?.cancel()
            collapseWork = nil
            if !isExpanded {
                isExpanded = true
                store.panelOpened()
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
