import Foundation

final class EndpointStore {
    private let defaultsKey = "miclisten.savedEndpoints.v1"
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    private(set) var endpoints: [SavedEndpoint]

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.endpoints = Self.load(from: defaults, key: defaultsKey)
    }

    func upsert(_ endpoint: SavedEndpoint) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        endpoints.sort { $0.createdAt < $1.createdAt }
        save()
    }

    func delete(_ endpoint: SavedEndpoint) {
        endpoints.removeAll { $0.id == endpoint.id }
        try? keychain.deletePassword(account: endpointPasswordAccount(endpoint.id))
        for credential in endpoint.streamerCredentials {
            try? keychain.deletePassword(account: streamerPasswordAccount(endpoint.id, credential.name))
        }
        save()
    }

    func endpointPassword(for endpointID: UUID) throws -> String? {
        try keychain.password(account: endpointPasswordAccount(endpointID))
    }

    func setEndpointPassword(_ password: String?, for endpointID: UUID) throws {
        try keychain.setPassword(password, account: endpointPasswordAccount(endpointID))
    }

    func streamerPassword(endpointID: UUID, name: String) throws -> String? {
        try keychain.password(account: streamerPasswordAccount(endpointID, name))
    }

    func setStreamerPassword(_ password: String?, endpointID: UUID, name: String) throws {
        try keychain.setPassword(password, account: streamerPasswordAccount(endpointID, name))
        guard let index = endpoints.firstIndex(where: { $0.id == endpointID }) else {
            return
        }
        if password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            endpoints[index].streamerCredentials.removeAll { $0.name == name }
        } else if !endpoints[index].credentialNames.contains(name) {
            endpoints[index].streamerCredentials.append(StreamerCredential(name: name))
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(endpoints) else {
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [SavedEndpoint] {
        guard let data = defaults.data(forKey: key),
              let endpoints = try? JSONDecoder().decode([SavedEndpoint].self, from: data) else {
            return []
        }
        return endpoints.sorted { $0.createdAt < $1.createdAt }
    }

    private func endpointPasswordAccount(_ endpointID: UUID) -> String {
        "endpoint.\(endpointID.uuidString)"
    }

    private func streamerPasswordAccount(_ endpointID: UUID, _ name: String) -> String {
        "endpoint.\(endpointID.uuidString).streamer.\(name)"
    }
}
