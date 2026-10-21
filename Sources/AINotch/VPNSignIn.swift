import AppKit
import SwiftUI
import VPNCore

/// The VPN's sign-in window. The notch never takes typing, so a password, a key's passphrase or
/// a challenge's response is asked here, in a small floating window near the notch that does.
/// Its close button (or Cancel) disconnects: OpenVPN would otherwise wait for the answer.
@MainActor
final class VPNSignInController: NSObject, NSWindowDelegate {
    static let shared = VPNSignInController()
    private var window: NSPanel?
    private var prompt: VPNPrompt?
    private weak var store: VPNStore?

    func show(prompt: VPNPrompt, profile: VPNProfileInfo?, store: VPNStore) {
        guard prompt.kind != .webAuth else { return }
        self.prompt = prompt
        self.store = store
        let view = VPNSignInView(prompt: prompt, profileName: profile?.name ?? "VPN", profileId: profile?.id ?? "",
                                 submit: { [weak self] username, password, response, remember in
                                     self?.submit(username: username, password: password, response: response, remember: remember)
                                 },
                                 cancel: { [weak self] in self?.cancel() })
        let panel = window ?? makePanel()
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        panel.title = "Sign in to \(profile?.name ?? "VPN")"
        place(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The prompt is gone (answered, or the session ended): the window goes too.
    func close() {
        prompt = nil
        if window?.isVisible == true { window?.orderOut(nil) }
    }

    private func submit(username: String, password: String, response: String?, remember: Bool?) {
        guard let prompt, let store else { return }
        close()
        Task { await store.answer(prompt, username: username, password: password, response: response, remember: remember) }
    }

    private func cancel() {
        close()
        store?.disconnect()
    }

    func windowWillClose(_ notification: Notification) {
        // The close button: as Cancel.
        if prompt != nil { cancel() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220), styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        window = panel
        return panel
    }

    /// Under the notch, on its screen.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, 24) - 80
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: top - size.height))
    }
}

private struct VPNSignInView: View {
    let prompt: VPNPrompt
    let profileName: String
    let profileId: String
    var submit: (String, String, String?, Bool?) -> Void
    var cancel: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var response = ""
    @State private var remember: Bool
    @FocusState private var focus: Field?

    enum Field { case username, password, response }

    init(prompt: VPNPrompt, profileName: String, profileId: String,
         submit: @escaping (String, String, String?, Bool?) -> Void, cancel: @escaping () -> Void) {
        self.prompt = prompt
        self.profileName = profileName
        self.profileId = profileId
        self.submit = submit
        self.cancel = cancel
        _username = State(initialValue: VPNStore.savedUsername(profileId))
        _remember = State(initialValue: VPNStore.hasSavedPassword(profileId))
    }

    private var asksUsername: Bool { prompt.kind == .password || prompt.kind == .usernameOnly }
    private var asksPassword: Bool { prompt.kind == .password || prompt.kind == .privateKey }

    private var headline: String {
        switch prompt.kind {
        case .privateKey: return "Unlock the private key"
        case .challenge: return "Answer the challenge"
        default: return "Sign in"
        }
    }

    private var canSend: Bool {
        if asksUsername, username.isEmpty { return false }
        if prompt.asksResponse, prompt.responseRequired, response.isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").font(.system(size: 24)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 14, weight: .semibold))
                    Text(profileName).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let failure = prompt.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if prompt.asksResponse, let text = prompt.text, !text.isEmpty {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                if asksUsername {
                    TextField("Username", text: $username).focused($focus, equals: .username)
                }
                if asksPassword {
                    SecureField(prompt.kind == .privateKey ? "Passphrase" : "Password", text: $password).focused($focus, equals: .password)
                }
                if prompt.asksResponse {
                    if prompt.echo {
                        TextField("Response", text: $response).focused($focus, equals: .response)
                    } else {
                        SecureField("Response", text: $response).focused($focus, equals: .response)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { if canSend { send() } }
            if prompt.kind == .password {
                Toggle("Remember the password in my Keychain", isOn: $remember)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(prompt.kind == .challenge ? "Send" : "Connect", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            focus = asksUsername && username.isEmpty ? .username : asksPassword ? .password : .response
        }
    }

    private func send() {
        submit(username, password, prompt.asksResponse ? response : nil, prompt.kind == .password ? remember : nil)
    }
}
