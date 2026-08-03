import AVFoundation
import Combine
import Foundation

enum PlaybackStatus: Equatable {
    case connecting
    case live
    case buffering
    case paused
    case failed(String)

    var title: String {
        switch self {
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .buffering: return "Buffering"
        case .paused: return "Paused"
        case .failed: return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .live: return "waveform"
        case .buffering: return "hourglass"
        case .paused: return "pause.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var isActive: Bool {
        switch self {
        case .failed:
            return false
        case .connecting, .live, .buffering, .paused:
            return true
        }
    }
}

struct PlaybackSession: Identifiable {
    let id: String
    let endpointID: UUID
    let targetID: String
    let targetName: String
    let device: AudioDevice
    let player: AVPlayer
    var status: PlaybackStatus
    var volume: Double
    var message: String?
    var observations: [NSKeyValueObservation]
    var notificationTokens: [NSObjectProtocol]
}

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var sessions: [String: PlaybackSession] = [:]

    func sessionID(target: StreamerTarget, device: AudioDevice) -> String {
        "\(target.id)|device.\(device.id)"
    }

    func session(for target: StreamerTarget, device: AudioDevice) -> PlaybackSession? {
        sessions[sessionID(target: target, device: device)]
    }

    func isPlaying(target: StreamerTarget, device: AudioDevice) -> Bool {
        session(for: target, device: device)?.status.isActive == true
    }

    func start(target: StreamerTarget, device: AudioDevice, client: MicListenClient) throws {
        let id = sessionID(target: target, device: device)
        if let existing = sessions.removeValue(forKey: id) {
            tearDown(existing)
        }

        try configureAudioSession()

        let streamURL = client.streamURL(baseURL: target.baseURL, deviceID: device.id)
        var headers = [
            "Accept": "audio/mpeg",
            "Cache-Control": "no-store"
        ]
        if let cookieHeader = client.cookieHeader(for: streamURL) {
            headers["Cookie"] = cookieHeader
        }

        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1

        let observationOptions: NSKeyValueObservingOptions = [.initial, .new]
        let itemObservation = item.observe(\AVPlayerItem.status, options: observationOptions) { [weak self] item, _ in
            Task { @MainActor in
                self?.syncItemStatus(item.status, item: item, sessionID: id)
            }
        }
        let timeObservation = player.observe(\AVPlayer.timeControlStatus, options: observationOptions) { [weak self] player, _ in
            Task { @MainActor in
                self?.syncTimeControlStatus(player.timeControlStatus, sessionID: id)
            }
        }
        let failedToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                self?.setStatus(.failed(error?.localizedDescription ?? "The stream stopped."), sessionID: id)
            }
        }
        let endedToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setStatus(.paused, message: "Stream ended.", sessionID: id)
            }
        }

        sessions[id] = PlaybackSession(
            id: id,
            endpointID: target.endpointID,
            targetID: target.id,
            targetName: target.displayName,
            device: device,
            player: player,
            status: .connecting,
            volume: 1,
            message: nil,
            observations: [itemObservation, timeObservation],
            notificationTokens: [failedToken, endedToken]
        )
        player.play()
    }

    func stop(target: StreamerTarget, device: AudioDevice) {
        stop(sessionID: sessionID(target: target, device: device))
    }

    func stop(sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        tearDown(session)
        deactivateAudioSessionIfIdle()
    }

    func stopAll(forEndpoint endpointID: UUID) {
        let ids = sessions.values
            .filter { $0.endpointID == endpointID }
            .map(\.id)
        ids.forEach(stop(sessionID:))
    }

    func stopAll() {
        let ids = Array(sessions.keys)
        ids.forEach(stop(sessionID:))
    }

    func setVolume(_ volume: Double, sessionID: String) {
        guard var session = sessions[sessionID] else {
            return
        }
        let clamped = min(max(volume, 0), 1)
        session.volume = clamped
        session.player.volume = Float(clamped)
        sessions[sessionID] = session
    }

    func volume(sessionID: String) -> Double {
        sessions[sessionID]?.volume ?? 1
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)
    }

    private func deactivateAudioSessionIfIdle() {
        guard sessions.isEmpty else {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func syncItemStatus(_ status: AVPlayerItem.Status, item: AVPlayerItem, sessionID: String) {
        guard sessions[sessionID] != nil else {
            return
        }
        switch status {
        case .readyToPlay:
            setStatus(.live, sessionID: sessionID)
        case .failed:
            setStatus(.failed(item.error?.localizedDescription ?? "The stream could not be played."), sessionID: sessionID)
        case .unknown:
            break
        @unknown default:
            setStatus(.failed("The stream entered an unknown player state."), sessionID: sessionID)
        }
    }

    private func syncTimeControlStatus(_ status: AVPlayer.TimeControlStatus, sessionID: String) {
        guard let current = sessions[sessionID]?.status, current.isActive else {
            return
        }
        switch status {
        case .playing:
            setStatus(.live, sessionID: sessionID)
        case .waitingToPlayAtSpecifiedRate:
            setStatus(.buffering, sessionID: sessionID)
        case .paused:
            if current != .connecting {
                setStatus(.paused, sessionID: sessionID)
            }
        @unknown default:
            break
        }
    }

    private func setStatus(_ status: PlaybackStatus, message: String? = nil, sessionID: String) {
        guard var session = sessions[sessionID] else {
            return
        }
        session.status = status
        session.message = message
        sessions[sessionID] = session
    }

    private func tearDown(_ session: PlaybackSession) {
        session.observations.forEach { $0.invalidate() }
        session.notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        session.player.pause()
        session.player.replaceCurrentItem(with: nil)
    }
}
