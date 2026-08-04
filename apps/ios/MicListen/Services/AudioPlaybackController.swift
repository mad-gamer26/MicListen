import AVFoundation
import Combine
import Darwin
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
    fileprivate let runtime: AudioStreamRuntime
    var status: PlaybackStatus
    var volume: Double
    var message: String?
}

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var sessions: [String: PlaybackSession] = [:]
    @Published private var targetVolumes: [String: Double] = [:]

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

        let runtime = AudioStreamRuntime(socket: client.audioWebSocketTask(baseURL: target.baseURL, deviceID: device.id))

        sessions[id] = PlaybackSession(
            id: id,
            endpointID: target.endpointID,
            targetID: target.id,
            targetName: target.displayName,
            device: device,
            runtime: runtime,
            status: .connecting,
            volume: 1,
            message: nil
        )
        runtime.setVolume(effectiveVolume(deviceVolume: 1, targetID: target.id))
        runtime.receiveTask = Task.detached(priority: .userInitiated) { [weak self, weak runtime] in
            guard let runtime else {
                return
            }
            await self?.receiveAudio(sessionID: id, runtime: runtime)
        }
        runtime.start()
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
        session.runtime.setVolume(effectiveVolume(deviceVolume: clamped, targetID: session.targetID))
        sessions[sessionID] = session
    }

    func volume(sessionID: String) -> Double {
        sessions[sessionID]?.volume ?? 1
    }

    func streamerVolume(target: StreamerTarget) -> Double {
        targetVolumes[target.id] ?? 1
    }

    func setStreamerVolume(_ volume: Double, target: StreamerTarget) {
        let clamped = min(max(volume, 0), 1)
        targetVolumes[target.id] = clamped

        for session in sessions.values where session.targetID == target.id {
            session.runtime.setVolume(effectiveVolume(deviceVolume: session.volume, targetID: session.targetID))
        }
    }

    private func effectiveVolume(deviceVolume: Double, targetID: String) -> Double {
        deviceVolume * (targetVolumes[targetID] ?? 1)
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audioSession.setPreferredIOBufferDuration(0.01)
        try audioSession.setActive(true)
    }

    private func deactivateAudioSessionIfIdle() {
        guard sessions.isEmpty else {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        session.runtime.stop()
    }

    nonisolated private func receiveAudio(sessionID: String, runtime: AudioStreamRuntime) async {
        let decoder = JSONDecoder()

        do {
            while !Task.isCancelled && !runtime.isStopped {
                let message = try await runtime.receive()
                switch message {
                case .string(let text):
                    let payload = try decoder.decode(AudioSocketMessage.self, from: Data(text.utf8))
                    try await handleSocketMessage(payload, sessionID: sessionID, runtime: runtime)
                case .data(let data):
                    runtime.pushAudio(data)
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled && !runtime.isStopped else {
                return
            }
            await MainActor.run {
                self.setStatus(.failed(Self.playbackErrorMessage(for: error)), sessionID: sessionID)
            }
        }
    }

    nonisolated private func handleSocketMessage(
        _ message: AudioSocketMessage,
        sessionID: String,
        runtime: AudioStreamRuntime
    ) async throws {
        switch message.type {
        case "format":
            guard message.encoding == "pcm_s16le" else {
                throw MicListenError.malformedResponse("The stream used an unsupported audio encoding.")
            }
            guard let sampleRate = message.sampleRate, sampleRate > 0,
                  let channels = message.channels, channels > 0 else {
                throw MicListenError.malformedResponse("The stream did not include usable audio format details.")
            }
            try runtime.configure(sampleRate: sampleRate, channels: channels)
            await MainActor.run {
                self.setStatus(.live, sessionID: sessionID)
            }
        case "error":
            throw MicListenError.server(status: 503, message: message.message ?? "The stream failed.")
        default:
            break
        }
    }

    private static func playbackErrorMessage(for error: Error) -> String {
        if let micListenError = error as? MicListenError {
            return micListenError.localizedDescription
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return "The stream stopped."
        }
        return error.localizedDescription
    }
}

private struct AudioSocketMessage: Decodable {
    let type: String
    let encoding: String?
    let sampleRate: Double?
    let channels: Int?
    let message: String?
}

private final class AudioStreamRuntime: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    let player = PCMStreamPlayer()
    var receiveTask: Task<Void, Never>?

    private let lock = NSLock()
    private var stopped = false
    private var currentVolume = 1.0

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    func start() {
        socket.resume()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await socket.receive()
    }

    func configure(sampleRate: Double, channels: Int) throws {
        let volume = try lock.withLock {
            guard !stopped else {
                throw URLError(.cancelled)
            }
            return currentVolume
        }
        try player.configure(sampleRate: sampleRate, channels: channels, volume: volume)
        if isStopped {
            player.stop()
            throw URLError(.cancelled)
        }
    }

    func pushAudio(_ data: Data) {
        guard !isStopped else {
            return
        }
        player.push(data)
    }

    func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        lock.withLock {
            currentVolume = clamped
        }
        player.setVolume(clamped)
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else {
                return false
            }
            stopped = true
            return true
        }
        guard shouldStop else {
            return
        }
        receiveTask?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        player.stop()
    }
}

private final class PCMStreamPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: PCMFrameRingBuffer?

    func configure(sampleRate: Double, channels: Int, volume: Double) throws {
        let channelCount = max(1, min(channels, 2))
        let outputSampleRate = AVAudioSession.sharedInstance().sampleRate
        let playbackSampleRate = outputSampleRate > 0 ? outputSampleRate : sampleRate
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw MicListenError.malformedResponse("The stream audio format is not supported.")
        }

        let nextEngine = AVAudioEngine()
        let nextRingBuffer = PCMFrameRingBuffer(
            sourceSampleRate: sampleRate,
            outputSampleRate: playbackSampleRate,
            channels: channelCount
        )
        let nextSourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            nextRingBuffer.render(frameCount: Int(frameCount), to: audioBufferList)
            return noErr
        }

        nextEngine.attach(nextSourceNode)
        nextEngine.connect(nextSourceNode, to: nextEngine.mainMixerNode, format: format)
        nextEngine.mainMixerNode.outputVolume = Float(min(max(volume, 0), 1))
        nextEngine.prepare()
        try nextEngine.start()

        lock.withLock {
            stopLocked()
            engine = nextEngine
            sourceNode = nextSourceNode
            ringBuffer = nextRingBuffer
        }
    }

    func push(_ data: Data) {
        let buffer = lock.withLock { ringBuffer }
        buffer?.push(data)
    }

    func setVolume(_ volume: Double) {
        let activeEngine = lock.withLock { self.engine }
        activeEngine?.mainMixerNode.outputVolume = Float(min(max(volume, 0), 1))
    }

    func stop() {
        lock.withLock {
            stopLocked()
        }
    }

    private func stopLocked() {
        engine?.stop()
        if let engine, let sourceNode {
            engine.detach(sourceNode)
        }
        ringBuffer = nil
        sourceNode = nil
        engine = nil
    }
}

private final class PCMFrameRingBuffer: @unchecked Sendable {
    private let channels: Int
    private let capacity: Int
    private let startThreshold: Int
    private let trimThreshold: Int
    private let trimTarget: Int
    private let ratio: Double
    private let lock = NSLock()

    private var buffers: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var phase = 0.0
    private var started = false

    init(sourceSampleRate: Double, outputSampleRate: Double, channels: Int) {
        let framesPerSecond = max(1, Int(sourceSampleRate.rounded()))
        self.channels = max(1, channels)
        self.capacity = max(framesPerSecond * 2, 2_048)
        self.startThreshold = max(Int(Double(framesPerSecond) * 0.03), 2)
        self.trimThreshold = max(Int(Double(framesPerSecond) * 0.2), 2)
        self.trimTarget = max(Int(ceil(Double(framesPerSecond) * 0.06)), 2)
        self.ratio = sourceSampleRate / max(outputSampleRate, 1)
        self.buffers = Array(repeating: Array(repeating: 0, count: capacity), count: self.channels)
    }

    func push(_ data: Data) {
        let frameByteCount = channels * MemoryLayout<Int16>.size
        guard frameByteCount > 0, data.count >= frameByteCount else {
            return
        }

        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            let frameCount = rawBuffer.count / frameByteCount
            lock.withLock {
                for frame in 0..<frameCount {
                    if availableFrames >= capacity - 1 {
                        readIndex = (readIndex + 1) % capacity
                        availableFrames -= 1
                    }

                    for channel in 0..<channels {
                        let byteOffset = (frame * channels + channel) * MemoryLayout<Int16>.size
                        let unsignedValue = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
                        let signedValue = Int16(bitPattern: unsignedValue)
                        buffers[channel][writeIndex] = Float(signedValue) / 32768
                    }

                    writeIndex = (writeIndex + 1) % capacity
                    availableFrames += 1
                }

                if availableFrames > trimThreshold {
                    let dropped = availableFrames - trimTarget
                    readIndex = (readIndex + dropped) % capacity
                    availableFrames = trimTarget
                    phase = 0
                }
                if availableFrames >= startThreshold {
                    started = true
                }
            }
        }
    }

    func render(frameCount: Int, to audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        clear(outputBuffers)

        lock.withLock {
            guard started, availableFrames >= 2 else {
                if availableFrames < 2 {
                    started = false
                }
                return
            }

            if outputBuffers.count == 1, Int(outputBuffers[0].mNumberChannels) > 1 {
                renderInterleaved(frameCount: frameCount, to: outputBuffers)
            } else {
                renderNonInterleaved(frameCount: frameCount, to: outputBuffers)
            }
        }
    }

    private func renderNonInterleaved(
        frameCount: Int,
        to outputBuffers: UnsafeMutableAudioBufferListPointer
    ) {
        for frame in 0..<frameCount {
            guard availableFrames >= 2 else {
                started = false
                break
            }

            let nextIndex = (readIndex + 1) % capacity
            for outputIndex in 0..<outputBuffers.count {
                guard let data = outputBuffers[outputIndex].mData else {
                    continue
                }
                let samples = data.assumingMemoryBound(to: Float.self)
                let sourceChannel = min(outputIndex, channels - 1)
                let current = buffers[sourceChannel][readIndex]
                let next = buffers[sourceChannel][nextIndex]
                samples[frame] = current + (next - current) * Float(phase)
            }

            advancePhase()
        }
    }

    private func renderInterleaved(
        frameCount: Int,
        to outputBuffers: UnsafeMutableAudioBufferListPointer
    ) {
        let outputChannelCount = Int(outputBuffers[0].mNumberChannels)
        guard let data = outputBuffers[0].mData else {
            return
        }
        let samples = data.assumingMemoryBound(to: Float.self)

        for frame in 0..<frameCount {
            guard availableFrames >= 2 else {
                started = false
                break
            }

            let nextIndex = (readIndex + 1) % capacity
            for outputChannel in 0..<outputChannelCount {
                let sourceChannel = min(outputChannel, channels - 1)
                let current = buffers[sourceChannel][readIndex]
                let next = buffers[sourceChannel][nextIndex]
                samples[frame * outputChannelCount + outputChannel] = current + (next - current) * Float(phase)
            }

            advancePhase()
        }
    }

    private func advancePhase() {
        phase += ratio
        while phase >= 1 && availableFrames > 1 {
            phase -= 1
            readIndex = (readIndex + 1) % capacity
            availableFrames -= 1
        }
    }

    private func clear(_ outputBuffers: UnsafeMutableAudioBufferListPointer) {
        for index in 0..<outputBuffers.count {
            guard let data = outputBuffers[index].mData else {
                continue
            }
            memset(data, 0, Int(outputBuffers[index].mDataByteSize))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
