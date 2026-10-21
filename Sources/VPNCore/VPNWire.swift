import Foundation

// What the app and the helper say over the control socket: one JSON request on one line, one
// JSON reply on one line, then the connection closes.

public struct VPNRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable {
        case status
        /// Check and keep a profile: `name` and `config` (the .ovpn's text).
        case importProfile = "import"
        case rename
        case delete
        case connect
        case disconnect
        /// Answer the open prompt (`prompt` is its id): username, password, response.
        case answer
        /// The last lines of OpenVPN's log.
        case log
    }

    public var op: Op
    public var id: String?
    public var name: String?
    public var config: String?
    public var prompt: Int?
    public var username: String?
    public var password: String?
    public var response: String?

    public init(_ op: Op, id: String? = nil, name: String? = nil, config: String? = nil, prompt: Int? = nil,
                username: String? = nil, password: String? = nil, response: String? = nil) {
        self.op = op
        self.id = id
        self.name = name
        self.config = config
        self.prompt = prompt
        self.username = username
        self.password = password
        self.response = response
    }
}

public struct VPNReply: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: VPNStatus?
    /// import: the new profile and the lines left out.
    public var profile: VPNProfileInfo?
    public var dropped: [String]?
    public var log: [String]?

    public init(ok: Bool, error: String? = nil, status: VPNStatus? = nil, profile: VPNProfileInfo? = nil,
                dropped: [String]? = nil, log: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.profile = profile
        self.dropped = dropped
        self.log = log
    }

    public static func fail(_ error: String) -> VPNReply { VPNReply(ok: false, error: error) }
}

public struct VPNStatus: Codable, Equatable, Sendable {
    public var version: String
    /// OpenVPN is installed beside the helper.
    public var engine: Bool
    public var profiles: [VPNProfileInfo]
    public var session: VPNSession?
    /// How the last session ended, for "dropped" and its reason.
    public var lastEnd: VPNEnd?

    public init(version: String, engine: Bool, profiles: [VPNProfileInfo], session: VPNSession?, lastEnd: VPNEnd?) {
        self.version = version
        self.engine = engine
        self.profiles = profiles
        self.session = session
        self.lastEnd = lastEnd
    }
}

public struct VPNProfileInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var servers: [String]
    public var asksPassword: Bool
    public var importedAt: Double

    public init(id: String, name: String, servers: [String], asksPassword: Bool, importedAt: Double) {
        self.id = id
        self.name = name
        self.servers = servers
        self.asksPassword = asksPassword
        self.importedAt = importedAt
    }
}

public enum VPNPhase: String, Codable, Sendable {
    case starting, resolving, connecting, waiting, authenticating, authPending, gettingConfig
    case assigningIP, addingRoutes, connected, reconnecting, exiting

    /// OpenVPN's state name.
    public init(openvpn name: String) {
        switch name {
        case "RESOLVE": self = .resolving
        case "TCP_CONNECT", "CONNECTING": self = .connecting
        case "WAIT": self = .waiting
        case "AUTH": self = .authenticating
        case "AUTH_PENDING": self = .authPending
        case "GET_CONFIG": self = .gettingConfig
        case "ASSIGN_IP": self = .assigningIP
        case "ADD_ROUTES": self = .addingRoutes
        case "CONNECTED": self = .connected
        case "RECONNECTING": self = .reconnecting
        case "EXITING": self = .exiting
        default: self = .connecting
        }
    }

    public var label: String {
        switch self {
        case .starting: return "Starting"
        case .resolving: return "Looking up the server"
        case .connecting: return "Connecting"
        case .waiting: return "Waiting for the server"
        case .authenticating: return "Signing in"
        case .authPending: return "Waiting for sign-in"
        case .gettingConfig: return "Getting settings"
        case .assigningIP: return "Assigning address"
        case .addingRoutes: return "Adding routes"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .exiting: return "Disconnecting"
        }
    }
}

/// What the helper waits on the user for. `id` grows with each new prompt, so an answer to an
/// old one is not applied to the next.
public struct VPNPrompt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Username and password, perhaps with a static challenge (`text`, `echo`).
        case password
        case usernameOnly
        /// The private key's passphrase.
        case privateKey
        /// A dynamic (CRV1) or CR_TEXT challenge: only a response.
        case challenge
        /// A sign-in page in the browser (`url`).
        case webAuth
    }

    public var id: Int
    public var kind: Kind
    public var text: String?
    public var echo: Bool
    public var responseRequired: Bool
    public var url: String?
    /// Why the last attempt failed ("Wrong username or password", the server's reason).
    public var failure: String?

    public init(id: Int, kind: Kind, text: String? = nil, echo: Bool = false, responseRequired: Bool = false,
                url: String? = nil, failure: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.echo = echo
        self.responseRequired = responseRequired
        self.url = url
        self.failure = failure
    }

    /// A challenge's response field shows.
    public var asksResponse: Bool { kind == .challenge || (kind == .password && text != nil) }
}

public struct VPNSession: Codable, Equatable, Sendable {
    public var profileId: String
    public var phase: VPNPhase
    public var detail: String?
    public var startedAt: Double
    public var connectedAt: Double?
    public var localIP: String?
    public var localIPv6: String?
    public var remoteIP: String?
    public var remotePort: String?
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var prompt: VPNPrompt?
    /// The last failure while still trying (a refused password, a server that does not answer).
    public var problem: String?

    public init(profileId: String, phase: VPNPhase, startedAt: Double) {
        self.profileId = profileId
        self.phase = phase
        self.startedAt = startedAt
        bytesIn = 0
        bytesOut = 0
    }
}

public struct VPNEnd: Codable, Equatable, Sendable {
    public var profileId: String
    public var at: Double
    /// Disconnect was asked for (by the app, or the helper stopping).
    public var byUser: Bool
    public var wasConnected: Bool
    public var reason: String?

    public init(profileId: String, at: Double, byUser: Bool, wasConnected: Bool, reason: String?) {
        self.profileId = profileId
        self.at = at
        self.byUser = byUser
        self.wasConnected = wasConnected
        self.reason = reason
    }
}

public enum VPNWire {
    /// The largest request the helper reads: a profile and its JSON escaping.
    public static let maxRequest = 2 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
