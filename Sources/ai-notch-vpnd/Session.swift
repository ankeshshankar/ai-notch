import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One OpenVPN run for one profile, driven through its management interface. Everything runs on
/// the daemon's queue.
final class Session: @unchecked Sendable {
    let profile: VPNProfileInfo
    private(set) var info: VPNSession
    /// The last 200 lines OpenVPN logged (verb 3: no secrets).
    private(set) var log: [String] = []
    private(set) var isStopping = false
    private(set) var wasConnected = false
    /// The session, OpenVPN's exit status or signal, and whether it was a signal.
    var onEnd: ((Session, Int32, Bool) -> Void)?

    private let config: String
    private let queue: DispatchQueue
    private let nextPromptId: () -> Int
    private var process: Process?
    private var management: Int32 = -1
    private var reader: DispatchSourceRead?
    private var pending = Data()
    /// What the next password request carries: a static challenge from the request itself, a
    /// dynamic one from the failure before it, a CR_TEXT one answered with cr-response.
    private var staticChallenge: MgmtEvent.StaticChallenge?
    private var dynamicChallenge: MgmtEvent.DynamicChallenge?
    private var crText = false
    private var lastFailure: String?
    private var fatal: String?
    private var ended = false

    init(profile: VPNProfileInfo, config: String, queue: DispatchQueue, nextPromptId: @escaping () -> Int) {
        self.profile = profile
        self.config = config
        self.queue = queue
        self.nextPromptId = nextPromptId
        info = VPNSession(profileId: profile.id, phase: .starting, startedAt: Date().timeIntervalSince1970)
    }

    /// OpenVPN with the checked profile, then everything that must hold whatever the profile
    /// says (later options win): no scripts beyond OpenVPN's own (its DNS script), the
    /// management interface the helper reads, passwords asked through it.
    private var arguments: [String] {
        ["--config", config,
         "--script-security", "1",
         "--management", VPNPaths.managementSocket, "unix",
         "--management-client-user", "root",
         "--management-hold",
         "--management-query-passwords",
         "--auth-retry", "interact",
         "--verb", "3",
         "--setenv", "IV_GUI_VER", "AI-Notch-VPN-\(VPNBuild.version)",
         "--setenv", "IV_SSO", "webauth,crtext"]
    }

    /// Starts OpenVPN; a reason when it could not.
    func start() -> String? {
        unlink(VPNPaths.managementSocket)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: VPNPaths.openvpn)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let logFD = open(VPNPaths.log, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
        if logFD >= 0 {
            let handle = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        let queue = self.queue
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let signaled = finished.terminationReason == .uncaughtSignal
            queue.async { [weak self] in self?.finish(status: status, signaled: signaled) }
        }
        do {
            try process.run()
        } catch {
            return "OpenVPN did not start: \(error.localizedDescription)"
        }
        self.process = process
        connectManagement(attempt: 0)
        return nil
    }

    /// Disconnect: OpenVPN is asked to exit (it takes its routes and DNS back); SIGTERM after
    /// 6 s, SIGKILL after 12.
    func stop() {
        guard !ended else { return }
        isStopping = true
        info.phase = .exiting
        info.prompt = nil
        if !send("signal SIGTERM") { process?.terminate() }
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.ended, let process = self.process, process.isRunning else { return }
            process.terminate()
        }
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.ended, let process = self.process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// The answer to prompt `id`; a reason when it is not taken.
    func answer(prompt id: Int, username: String, password: String, response: String?) -> String? {
        guard let prompt = info.prompt, prompt.id == id else { return "That question has passed." }
        var lines: [String]?
        switch prompt.kind {
        case .password:
            lines = Mgmt.authAnswer(username: username, password: password, response: response, challenge: staticChallenge, dynamic: nil)
        case .usernameOnly:
            lines = Mgmt.quote(username).map { ["username \"Auth\" \($0)"] }
        case .privateKey:
            lines = Mgmt.quote(password).map { ["password \"Private Key\" \($0)"] }
        case .challenge:
            if crText {
                lines = ["cr-response \(Mgmt.base64(response ?? ""))"]
            } else if let dynamic = dynamicChallenge {
                lines = Mgmt.authAnswer(username: "", password: "", response: response, challenge: nil, dynamic: dynamic)
            }
        case .webAuth:
            return "The sign-in page answers this one."
        }
        guard let lines else { return "A value holds a line break or is longer than 240 characters." }
        for line in lines {
            guard send(line) else { return "OpenVPN is not answering." }
        }
        if prompt.kind == .challenge {
            dynamicChallenge = nil
            crText = false
        }
        info.prompt = nil
        info.problem = nil
        lastFailure = nil
        info.phase = .authenticating
        return nil
    }

    func endReason(status: Int32, signaled: Bool) -> String? {
        if isStopping { return nil }
        if let fatal { return fatal }
        if let problem = info.problem { return problem }
        if signaled { return "OpenVPN was stopped (signal \(status)). Its log is in \(VPNPaths.log)." }
        return status == 0 ? nil : "OpenVPN stopped (exit \(status)). Its log is in \(VPNPaths.log)."
    }

    // MARK: Management interface

    private func connectManagement(attempt: Int) {
        guard !ended else { return }
        do {
            let fd = try UnixSocket.connect(VPNPaths.managementSocket)
            management = fd
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            reader.resume()
            self.reader = reader
            // Announce a client that knows username-only requests, then let it go.
            _ = send("version 4")
            _ = send("state on")
            _ = send("bytecount 2")
            _ = send("log on")
            _ = send("hold release")
        } catch {
            // OpenVPN opens the socket a moment after it starts; up to 10 s.
            guard attempt < 100 else {
                fatal = "OpenVPN's management interface did not open."
                process?.terminate()
                return
            }
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.connectManagement(attempt: attempt + 1) }
        }
    }

    @discardableResult
    private func send(_ command: String) -> Bool {
        guard management >= 0 else { return false }
        do {
            try UnixSocket.writeAll(management, Data((command + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(management, &buffer, buffer.count)
            if n > 0 {
                pending.append(contentsOf: buffer[0..<n])
                continue
            }
            if n == 0 { closeManagement() }
            break
        }
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            take(MgmtEvent.parse(line))
        }
        if pending.count > 1 << 20 { pending.removeAll() }
    }

    private func closeManagement() {
        reader?.cancel()
        reader = nil
        if management >= 0 { close(management) }
        management = -1
    }

    private func take(_ event: MgmtEvent) {
        switch event {
        case .state(let name, let detail, let localIP, let remoteIP, let remotePort, let localIPv6):
            let phase = VPNPhase(openvpn: name)
            info.phase = isStopping ? .exiting : phase
            info.detail = detail.isEmpty ? nil : detail
            if phase == .connected {
                wasConnected = true
                info.connectedAt = info.connectedAt ?? Date().timeIntervalSince1970
                info.localIP = localIP.isEmpty ? nil : localIP
                info.localIPv6 = localIPv6.isEmpty ? nil : localIPv6
                info.remoteIP = remoteIP.isEmpty ? nil : remoteIP
                info.remotePort = remotePort.isEmpty ? nil : remotePort
                info.problem = nil
                info.prompt = nil
                lastFailure = nil
            } else if phase == .reconnecting {
                info.connectedAt = nil
                info.prompt = nil
            }
        case .bytes(let received, let sent):
            info.bytesIn = received
            info.bytesOut = sent
        case .hold:
            // Each restart (a reconnect, a refused password) holds again: let it go on.
            if !isStopping { send("hold release") }
        case .needAuth(let usernameOnly, let challenge):
            staticChallenge = challenge
            if let dynamic = dynamicChallenge {
                ask(VPNPrompt(id: nextPromptId(), kind: .challenge, text: dynamic.text, echo: dynamic.echo,
                              responseRequired: dynamic.responseRequired))
            } else if usernameOnly {
                ask(VPNPrompt(id: nextPromptId(), kind: .usernameOnly, failure: lastFailure))
            } else {
                ask(VPNPrompt(id: nextPromptId(), kind: .password, text: challenge?.text, echo: challenge?.echo ?? false,
                              responseRequired: challenge != nil, failure: lastFailure))
            }
        case .needPrivateKey:
            ask(VPNPrompt(id: nextPromptId(), kind: .privateKey, failure: lastFailure))
        case .authFailed(let reason, let challenge):
            if let challenge {
                dynamicChallenge = challenge
            } else {
                lastFailure = reason ?? "The server refused the username or password."
                info.problem = lastFailure
            }
        case .privateKeyFailed:
            lastFailure = "Wrong passphrase for the private key."
            info.problem = lastFailure
        case .webAuth(let url):
            guard let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                appendLog("ignored a sign-in link that is not http(s)")
                return
            }
            ask(VPNPrompt(id: nextPromptId(), kind: .webAuth, url: url))
        case .crText(let echo, let text):
            crText = true
            ask(VPNPrompt(id: nextPromptId(), kind: .challenge, text: text, echo: echo, responseRequired: true))
        case .fatal(let text):
            fatal = text
            info.problem = text
        case .log(let text):
            appendLog(text)
        case .need(let text):
            appendLog("needs: \(text)")
            info.problem = "OpenVPN asks for something AI Notch cannot answer (\(text))."
        case .other:
            break
        }
    }

    private func ask(_ prompt: VPNPrompt) {
        guard !isStopping else { return }
        info.prompt = prompt
        info.phase = .authenticating
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func finish(status: Int32, signaled: Bool) {
        guard !ended else { return }
        ended = true
        closeManagement()
        unlink(VPNPaths.managementSocket)
        onEnd?(self, status, signaled)
    }
}
