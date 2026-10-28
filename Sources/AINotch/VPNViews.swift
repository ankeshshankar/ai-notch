import AppKit
import SwiftUI
import VPNCore

/// The footer's VPN chip: a shield in the connection's colour and the profile while connected
/// ("VPN off", "Connecting", "Sign in" otherwise). A click opens the VPN panel (and closes it).
struct VPNChip: View {
    @ObservedObject var vpn: VPNStore
    @ObservedObject var controller: NotchController

    var body: some View {
        let isOpen = controller.openPanel == NotchController.vpnPanel
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                controller.openPanel = isOpen ? nil : NotchController.vpnPanel
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: vpn.level == .connected ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isOpen ? Palette.onDone : Self.color(vpn.level))
                Text(vpn.chipText).font(.system(size: 10, weight: .semibold)).foregroundStyle(isOpen ? Palette.onDone : Palette.ink2)
            }
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(isOpen ? Palette.done : Palette.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    static func color(_ level: VPNStore.Level) -> Color {
        switch level {
        case .off: return Palette.ink3
        case .busy: return Palette.waiting
        case .connected: return Palette.done
        case .problem: return Palette.failed
        }
    }
}

/// The VPN panel, compact: a line per imported profile with its state and Connect or
/// Disconnect. The chevron opens the rest: each connection's address, time and traffic, the
/// server, Import… and the log. A problem or a sign-in waiting shows either way.
struct VPNPanel: View {
    @ObservedObject var vpn: VPNStore
    var now: Double
    @State private var showsLog = false
    /// The details are open; remembered.
    @AppStorage("vpn.panelDetails") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("VPN").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.done)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.doneHue.opacity(0.16)))
                if let working = vpn.working {
                    Text(working).font(.system(size: 10)).foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 6)
                if expanded, vpn.helper == .running {
                    InfoMark(text: Self.about)
                    if !vpn.profiles.isEmpty {
                        small(showsLog ? "Hide log" : "Log") {
                            showsLog.toggle()
                            if showsLog { vpn.loadLog() }
                        }
                    }
                    small("Import…") { vpn.importProfile() }
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        expanded.toggle()
                        if !expanded { showsLog = false }
                    }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.ink3)
                        .frame(width: 18, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Fewer details" : "Details, Import… and the log")
            }
            content
            if let note = vpn.note {
                Text(note).font(.system(size: 10)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .panelCard()
    }

    @ViewBuilder private var content: some View {
        switch vpn.helper {
        case .unknown:
            Text("—").font(.system(size: 12)).foregroundStyle(Palette.ink3)
        case .notInstalled:
            HStack(spacing: 8) {
                Text("The VPN helper is not installed. Setup installs it with your admin password, once.")
                    .font(.system(size: 11)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                small("Setup…") { SetupWindowController.shared.show(focus: .vpn) }
            }
        case .notRunning:
            Text("The VPN helper does not answer. It restarts by itself; if it stays this way, Setup → VPN can install it again.")
                .font(.system(size: 11)).foregroundStyle(Palette.waiting).fixedSize(horizontal: false, vertical: true)
        case .running:
            if let error = vpn.helperError {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.failed)
            }
            if vpn.needsUpdate {
                HStack(spacing: 8) {
                    Text("A newer VPN helper comes with this version of AI Notch.").font(.system(size: 11)).foregroundStyle(Palette.waiting)
                    Spacer(minLength: 6)
                    small("Update…") { vpn.install() }
                }
            }
            if vpn.status?.engine == false {
                Text("OpenVPN is missing beside the helper. Setup → VPN can install it again.").font(.system(size: 11)).foregroundStyle(Palette.failed)
            }
            if vpn.profiles.isEmpty {
                HStack(spacing: 8) {
                    Text("No profiles yet.").font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    Spacer(minLength: 6)
                    small("Import…") { vpn.importProfile() }
                }
            } else {
                VStack(alignment: .leading, spacing: expanded ? 6 : 4) {
                    ForEach(vpn.profiles) { profile in row(profile) }
                }
            }
            if vpn.session == nil, let end = vpn.status?.lastEnd, !end.byUser, let reason = end.reason {
                Text("\(vpn.profile(end.profileId)?.name ?? "VPN"): \(reason)")
                    .font(.system(size: 10)).foregroundStyle(Palette.failed).lineLimit(expanded ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(reason)
            }
            if expanded, showsLog { logView }
        }
    }

    private func row(_ profile: VPNProfileInfo) -> some View {
        let session = vpn.session?.profileId == profile.id ? vpn.session : nil
        // Closed, the second line only for what needs you: a problem, a sign-in.
        let showsDetail = expanded || session?.problem != nil || session?.prompt != nil
        return HStack(spacing: 8) {
            Image(systemName: session?.phase == .connected ? "lock.shield.fill" : "network")
                .font(.system(size: 11)).frame(width: 14)
                .foregroundStyle(session.map { $0.phase == .connected ? Palette.done : Palette.waiting } ?? Palette.ink2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.9)).lineLimit(1)
                    if !showsDetail, let session {
                        Text(short(session)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                }
                if showsDetail {
                    Text(detail(profile, session)).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(session?.problem != nil ? Palette.failed : Palette.ink3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            button(profile, session)
        }
        .help(session.map { detail(profile, $0) } ?? profile.servers.joined(separator: ", "))
    }

    /// Beside the name while the details are closed: how long it has been up, or its state.
    private func short(_ session: VPNSession) -> String {
        if session.phase == .connected, let since = session.connectedAt { return elapsed(now - since) }
        return session.phase.label + "…"
    }

    /// Under the name: the server when idle; the state, or address, time and traffic once connected.
    private func detail(_ profile: VPNProfileInfo, _ session: VPNSession?) -> String {
        guard let session else {
            let first = profile.servers.first ?? ""
            return profile.servers.count > 1 ? "\(first) +\(profile.servers.count - 1)" : first
        }
        if session.phase == .connected, let since = session.connectedAt {
            let address = session.localIP ?? session.localIPv6 ?? ""
            return [address, elapsed(now - since), "↓ \(VPNStore.bytes(session.bytesIn)) ↑ \(VPNStore.bytes(session.bytesOut))"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let problem = session.problem { return problem }
        if let prompt = session.prompt {
            return prompt.kind == .webAuth ? "Finish signing in in your browser" : "Waiting for your sign-in"
        }
        return session.phase.label + "…"
    }

    @ViewBuilder private func button(_ profile: VPNProfileInfo, _ session: VPNSession?) -> some View {
        if let session {
            HStack(spacing: 6) {
                if let prompt = session.prompt {
                    small(prompt.kind == .webAuth ? "Open page" : "Sign in…") {
                        if prompt.kind == .webAuth, let text = prompt.url, let url = URL(string: text) {
                            NSWorkspace.shared.open(url)
                        } else {
                            VPNSignInController.shared.show(prompt: prompt, profile: profile, store: vpn)
                        }
                    }
                }
                small(session.phase == .exiting ? "Disconnecting…" : session.phase == .connected ? "Disconnect" : "Cancel", urgent: session.phase == .connected) {
                    vpn.disconnect()
                }
                .disabled(session.phase == .exiting)
            }
        } else {
            small("Connect") { vpn.connect(profile.id) }
                .disabled(vpn.status?.engine != true)
        }
    }

    private var logView: some View {
        ScrollView(.vertical) {
            Text(vpn.log.suffix(40).joined(separator: "\n"))
                .font(.system(size: 9).monospaced()).foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.inset))
    }

    private func small(_ title: String, urgent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .medium))
                .foregroundStyle(urgent ? Palette.failed : Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(urgent ? Palette.failedHue.opacity(0.16) : Palette.chip))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    static let about = "OpenVPN, run by AI Notch's helper (a launch daemon installed once with your admin password). Profiles are .ovpn files; each is checked when imported: nothing that runs a program, loads code or reads a file by path as root is let through, and certificates must be inline. Passwords are asked in a small window (the notch never takes typing) and, if you choose, kept in your login Keychain. Disconnect takes the routes and DNS back. A connection keeps running when the notch closes or AI Notch quits."
}
