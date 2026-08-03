import Foundation

enum EndpointKind: String, Codable {
    case unknown
    case streamer
    case relay

    var title: String {
        switch self {
        case .unknown: return "Detecting"
        case .streamer: return "Streamer"
        case .relay: return "Relay"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .streamer: return "dot.radiowaves.left.and.right"
        case .relay: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct SavedEndpoint: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var baseURLString: String
    var createdAt: Date
    var lastResolvedKind: EndpointKind
    var streamerCredentials: [StreamerCredential]

    init(
        id: UUID = UUID(),
        name: String,
        baseURLString: String,
        createdAt: Date = Date(),
        lastResolvedKind: EndpointKind = .unknown,
        streamerCredentials: [StreamerCredential] = []
    ) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.createdAt = createdAt
        self.lastResolvedKind = lastResolvedKind
        self.streamerCredentials = streamerCredentials
    }

    var baseURL: URL? {
        URL(string: baseURLString)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        guard let url = baseURL else {
            return "MicListen"
        }
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }
        return url.absoluteString
    }

    var credentialNames: Set<String> {
        Set(streamerCredentials.map(\.name))
    }
}

struct StreamerCredential: Identifiable, Codable, Equatable {
    var name: String

    var id: String { name }
}

struct HealthPayload: Decodable, Equatable {
    let status: String
    let audioError: String?
    let version: String?
    let authentication: Bool?
    let connectedStreamers: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case audioError = "audio_error"
        case version
        case authentication
        case connectedStreamers = "connected_streamers"
    }

    var detectedKind: EndpointKind {
        connectedStreamers == nil ? .streamer : .relay
    }
}

struct DeviceListResponse: Decodable {
    let devices: [AudioDevice]
}

struct AudioDevice: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let kind: String
    let channels: Int
    let sampleRate: Int
    let hostAPI: String
    let isDefault: Bool
    let targetName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case channels
        case sampleRate = "sample_rate"
        case hostAPI = "host_api"
        case isDefault = "is_default"
        case targetName = "target_name"
    }

    var cleanName: String {
        name.replacingOccurrences(of: #" \[Loopback\]$"#, with: "", options: .regularExpression)
    }

    var kindTitle: String {
        kind == "output" ? "Output" : "Input"
    }

    var systemImage: String {
        kind == "output" ? "headphones" : "mic"
    }
}

struct RelayStreamerLink: Identifiable, Hashable {
    let name: String
    let baseURL: URL

    var id: String { baseURL.absoluteString }
}

struct StreamerTarget: Identifiable {
    let endpointID: UUID
    let name: String
    let baseURL: URL
    let sourceKind: EndpointKind
    var health: HealthPayload?
    var devices: [AudioDevice]
    var requiresPassword: Bool
    var problem: String?

    var id: String {
        "\(endpointID.uuidString)|\(baseURL.absoluteString)"
    }

    var displayName: String {
        name
    }

    var statusText: String {
        if requiresPassword {
            return "Password required"
        }
        if let problem {
            return problem
        }
        if let health, health.status != "ok" {
            return health.status.capitalized
        }
        return "Online"
    }
}

struct EndpointResolution {
    let endpointID: UUID
    let kind: EndpointKind
    let baseURL: URL
    let health: HealthPayload
    let targets: [StreamerTarget]
    let resolvedAt: Date
    let message: String?
}

enum EndpointLoadStatus: Equatable {
    case idle
    case loading
    case ready
    case needsPassword
    case failed
}

struct EndpointLoadState {
    var status: EndpointLoadStatus = .idle
    var resolution: EndpointResolution?
    var message: String?

    var isLoading: Bool {
        status == .loading
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PasswordRequest: Identifiable, Equatable {
    enum Scope: Equatable {
        case endpoint(UUID)
        case streamer(endpointID: UUID, name: String)
    }

    let id = UUID()
    let title: String
    let message: String
    let scope: Scope
}
