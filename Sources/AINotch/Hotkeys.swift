import AppKit
import Carbon.HIToolbox
import Combine
import NotchCore

/// Global keyboard shortcuts, through Carbon's hot keys (no Accessibility permission needed):
///
/// - ⌃⌥Space opens the notch, or closes it;
/// - ⌃⌥J jumps to the session that needs you (waiting first, else the one that finished last);
/// - while a prompt waits: ⌃⌥Y answers the oldest with Allow once (Approve plan), ⌃⌥N with
///   Deny (Keep planning). These two are registered only then, so they are free otherwise.
///
/// Setup → Effects → Keyboard shortcuts turns them off.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    static let enabledKey = "hotkeys.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private enum Key: UInt32 { case toggle = 1, jump, allow, deny }

    private var refs: [Key: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var watch: AnyCancellable?
    private weak var controller: NotchController?
    private weak var store: SessionStore?

    func start(controller: NotchController, store: SessionStore) {
        self.controller = controller
        self.store = store
        installHandler()
        apply()
        watch = store.approvals.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in MainActor.assumeIsolated { self?.setAnswerKeys(!pending.isEmpty) } }
    }

    /// After the Setup switch changes.
    func apply() {
        if Self.isEnabled {
            register(.toggle, keyCode: UInt32(kVK_Space))
            register(.jump, keyCode: UInt32(kVK_ANSI_J))
            setAnswerKeys(!(store?.approvals.pending.isEmpty ?? true))
        } else {
            for key in Array(refs.keys) { unregister(key) }
        }
    }

    private func setAnswerKeys(_ on: Bool) {
        if on && Self.isEnabled {
            register(.allow, keyCode: UInt32(kVK_ANSI_Y))
            register(.deny, keyCode: UInt32(kVK_ANSI_N))
        } else {
            unregister(.allow)
            unregister(.deny)
        }
    }

    private func register(_ key: Key, keyCode: UInt32) {
        guard refs[key] == nil else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x414E_4F54), id: key.rawValue) // "ANOT"
        let status = RegisterEventHotKey(keyCode, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[key] = ref }
    }

    private func unregister(_ key: Key) {
        guard let ref = refs.removeValue(forKey: key) else { return }
        UnregisterEventHotKey(ref)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == OSType(0x414E_4F54) else { return OSStatus(eventNotHandledErr) }
            let raw = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.shared.fire(raw) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ raw: UInt32) {
        guard let key = Key(rawValue: raw), let controller, let store else { return }
        switch key {
        case .toggle:
            controller.toggleFromKeyboard()
        case .jump:
            let target = store.sessions.first { $0.phase == .waiting }
                ?? store.sessions.filter { $0.phase == .idle && $0.finishedAt != nil }.max { ($0.finishedAt ?? 0) < ($1.finishedAt ?? 0) }
                ?? store.sessions.first
            if let target {
                controller.collapse()
                Jump.to(target)
            }
        case .allow, .deny:
            guard let first = store.approvals.pending.first(where: { $0.request.question == nil }) else { return }
            store.approvals.answer(first.id, key == .allow ? .allow : .deny)
        }
    }
}
