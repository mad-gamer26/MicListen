import Combine
import Foundation

struct EndpointOpenRequest: Equatable {
    let endpointID: UUID
    let nonce = UUID()
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var endpoints: [SavedEndpoint]
    @Published var selectedEndpointID: UUID? {
        didSet {
            if selectedEndpointID == nil, let oldValue {
                playback.stopAll(forEndpoint: oldValue)
            }
        }
    }
    @Published private(set) var endpointOpenRequest: EndpointOpenRequest?
    @Published private(set) var states: [UUID: EndpointLoadState] = [:]
    @Published var alert: AppAlert?

    let playback = AudioPlaybackController()

    private let store: EndpointStore
    private let client: MicListenClient
    private var hasRefreshedOnLaunch = false

    init(store: EndpointStore = EndpointStore(), client: MicListenClient = MicListenClient()) {
        self.store = store
        self.client = client
        self.endpoints = store.endpoints
        self.selectedEndpointID = nil
    }

    func state(for endpointID: UUID) -> EndpointLoadState {
        states[endpointID] ?? EndpointLoadState()
    }

    func endpoint(id: UUID?) -> SavedEndpoint? {
        guard let id else {
            return nil
        }
        return endpoints.first { $0.id == id }
    }

    func openEndpoint(_ endpointID: UUID) {
        selectedEndpointID = endpointID
        endpointOpenRequest = EndpointOpenRequest(endpointID: endpointID)
    }

    func closeSelectedEndpoint() {
        selectedEndpointID = nil
    }

    func refreshAllIfNeeded() async {
        guard !hasRefreshedOnLaunch else {
            return
        }
        hasRefreshedOnLaunch = true
        await refreshAll()
    }

    func refreshAll() async {
        for endpoint in endpoints {
            await refresh(endpointID: endpoint.id)
        }
    }

    func refresh(endpointID: UUID) async {
        guard var endpoint = endpoint(id: endpointID) else {
            return
        }

        var current = state(for: endpointID)
        current.status = .loading
        current.message = nil
        states[endpointID] = current

        do {
            let baseURL = try client.normalizedURL(from: endpoint.baseURLString)
            let endpointPassword = try store.endpointPassword(for: endpointID)
            let health = try await authenticatedHealth(baseURL: baseURL, password: endpointPassword)

            if health.detectedKind == .relay {
                let links = try await client.fetchRelayStreamers(baseURL: baseURL)
                var targets: [StreamerTarget] = []
                for link in links {
                    targets.append(await resolveRelayStreamer(link, endpoint: endpoint))
                }

                let count = health.connectedStreamers ?? 0
                let message = count > 0 && targets.isEmpty
                    ? "Relay is online, but no streamer links were found."
                    : nil
                endpoint.baseURLString = baseURL.absoluteString
                endpoint.lastResolvedKind = .relay
                replaceEndpoint(endpoint)
                states[endpointID] = EndpointLoadState(
                    status: .ready,
                    resolution: EndpointResolution(
                        endpointID: endpointID,
                        kind: .relay,
                        baseURL: baseURL,
                        health: health,
                        targets: targets,
                        resolvedAt: Date(),
                        message: message
                    ),
                    message: message
                )
            } else {
                let devices = try await authenticatedDevices(baseURL: baseURL, password: endpointPassword)
                let target = StreamerTarget(
                    endpointID: endpointID,
                    name: endpoint.displayName,
                    baseURL: baseURL,
                    sourceKind: .streamer,
                    health: health,
                    devices: devices,
                    requiresPassword: false,
                    problem: nil
                )
                endpoint.baseURLString = baseURL.absoluteString
                endpoint.lastResolvedKind = .streamer
                replaceEndpoint(endpoint)
                states[endpointID] = EndpointLoadState(
                    status: .ready,
                    resolution: EndpointResolution(
                        endpointID: endpointID,
                        kind: .streamer,
                        baseURL: baseURL,
                        health: health,
                        targets: [target],
                        resolvedAt: Date(),
                        message: nil
                    ),
                    message: nil
                )
            }
        } catch MicListenError.authenticationRequired(let message) {
            states[endpointID] = EndpointLoadState(status: .needsPassword, resolution: current.resolution, message: message)
        } catch {
            states[endpointID] = EndpointLoadState(status: .failed, resolution: current.resolution, message: error.localizedDescription)
        }
    }

    func addEndpoint(name: String, urlText: String, password: String) async -> Bool {
        do {
            let normalized = try client.normalizedURL(from: urlText)
            let endpoint = SavedEndpoint(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURLString: normalized.absoluteString
            )
            store.upsert(endpoint)
            if !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.setEndpointPassword(password, for: endpoint.id)
            }
            reloadFromStore(selecting: nil)
            return true
        } catch {
            alert = AppAlert(title: "Endpoint Not Added", message: error.localizedDescription)
            return false
        }
    }

    func updateEndpoint(_ endpoint: SavedEndpoint, name: String, urlText: String, password: String?) async -> Bool {
        do {
            let normalized = try client.normalizedURL(from: urlText)
            var updated = endpoint
            updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.baseURLString = normalized.absoluteString
            updated.lastResolvedKind = .unknown
            store.upsert(updated)
            if let password {
                try store.setEndpointPassword(password, for: endpoint.id)
            }
            states.removeValue(forKey: endpoint.id)
            reloadFromStore(selecting: nil)
            return true
        } catch {
            alert = AppAlert(title: "Endpoint Not Updated", message: error.localizedDescription)
            return false
        }
    }

    func deleteEndpoint(_ endpoint: SavedEndpoint) {
        playback.stopAll(forEndpoint: endpoint.id)
        store.delete(endpoint)
        states.removeValue(forKey: endpoint.id)
        reloadFromStore(selecting: selectedEndpointID == endpoint.id ? nil : selectedEndpointID)
    }

    func endpointPasswordRequest(for endpoint: SavedEndpoint) -> PasswordRequest {
        let message = state(for: endpoint.id).message?.lowercased() ?? ""
        let title = endpoint.lastResolvedKind == .relay || message.contains("relay")
            ? "Relay Password"
            : "Streamer Password"
        return PasswordRequest(
            title: title,
            message: endpoint.displayName,
            scope: .endpoint(endpoint.id)
        )
    }

    func streamerPasswordRequest(endpointID: UUID, name: String) -> PasswordRequest {
        PasswordRequest(
            title: "Streamer Password",
            message: name,
            scope: .streamer(endpointID: endpointID, name: name)
        )
    }

    func savePassword(_ password: String, for request: PasswordRequest) async {
        do {
            switch request.scope {
            case .endpoint(let endpointID):
                try store.setEndpointPassword(password, for: endpointID)
                await refresh(endpointID: endpointID)
            case .streamer(let endpointID, let name):
                try store.setStreamerPassword(password, endpointID: endpointID, name: name)
                reloadFromStore(selecting: endpointID)
                await refresh(endpointID: endpointID)
            }
        } catch {
            alert = AppAlert(title: "Password Not Saved", message: error.localizedDescription)
        }
    }

    func togglePlayback(target: StreamerTarget, device: AudioDevice) {
        if playback.isPlaying(target: target, device: device) {
            playback.stop(target: target, device: device)
            return
        }

        Task {
            do {
                try await ensureAuthenticated(target: target)
                try playback.start(target: target, device: device, client: client)
            } catch MicListenError.authenticationRequired(let message) {
                alert = AppAlert(title: "Password Required", message: message)
            } catch {
                alert = AppAlert(title: "Playback Failed", message: error.localizedDescription)
            }
        }
    }

    private func resolveRelayStreamer(_ link: RelayStreamerLink, endpoint: SavedEndpoint) async -> StreamerTarget {
        do {
            let password = try store.streamerPassword(endpointID: endpoint.id, name: link.name)
            let health = try await authenticatedHealth(baseURL: link.baseURL, password: password)
            let devices = try await authenticatedDevices(baseURL: link.baseURL, password: password)
            return StreamerTarget(
                endpointID: endpoint.id,
                name: link.name,
                baseURL: link.baseURL,
                sourceKind: .relay,
                health: health,
                devices: devices,
                requiresPassword: false,
                problem: nil
            )
        } catch MicListenError.authenticationRequired(let message) {
            return StreamerTarget(
                endpointID: endpoint.id,
                name: link.name,
                baseURL: link.baseURL,
                sourceKind: .relay,
                health: nil,
                devices: [],
                requiresPassword: true,
                problem: message
            )
        } catch {
            return StreamerTarget(
                endpointID: endpoint.id,
                name: link.name,
                baseURL: link.baseURL,
                sourceKind: .relay,
                health: nil,
                devices: [],
                requiresPassword: false,
                problem: error.localizedDescription
            )
        }
    }

    private func authenticatedHealth(baseURL: URL, password: String?) async throws -> HealthPayload {
        do {
            return try await client.fetchHealth(baseURL: baseURL)
        } catch MicListenError.authenticationRequired {
            guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MicListenError.authenticationRequired("Password required.")
            }
            try await client.login(baseURL: baseURL, password: password)
            return try await client.fetchHealth(baseURL: baseURL)
        }
    }

    private func authenticatedDevices(baseURL: URL, password: String?) async throws -> [AudioDevice] {
        do {
            return try await client.fetchDevices(baseURL: baseURL)
        } catch MicListenError.authenticationRequired {
            guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MicListenError.authenticationRequired("Password required.")
            }
            try await client.login(baseURL: baseURL, password: password)
            return try await client.fetchDevices(baseURL: baseURL)
        }
    }

    private func ensureAuthenticated(target: StreamerTarget) async throws {
        guard let endpoint = endpoint(id: target.endpointID) else {
            throw MicListenError.notMicListen("The saved endpoint no longer exists.")
        }

        if target.sourceKind == .relay,
           let relayBaseURL = endpoint.baseURL {
            let relayPassword = try store.endpointPassword(for: endpoint.id)
            _ = try await authenticatedHealth(baseURL: relayBaseURL, password: relayPassword)
            let streamerPassword = try store.streamerPassword(endpointID: endpoint.id, name: target.name)
            _ = try await authenticatedHealth(baseURL: target.baseURL, password: streamerPassword)
        } else {
            let password = try store.endpointPassword(for: endpoint.id)
            _ = try await authenticatedHealth(baseURL: target.baseURL, password: password)
        }
    }

    private func replaceEndpoint(_ endpoint: SavedEndpoint) {
        store.upsert(endpoint)
        reloadFromStore(selecting: selectedEndpointID)
    }

    private func reloadFromStore(selecting selection: UUID?) {
        endpoints = store.endpoints
        if let selection, endpoints.contains(where: { $0.id == selection }) {
            selectedEndpointID = selection
        } else {
            selectedEndpointID = nil
        }
    }
}
