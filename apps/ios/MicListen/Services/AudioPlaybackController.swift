import AVFoundation
import AudioToolbox
import Combine
import Darwin
import Foundation
import speex

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

private func micListenAudioQueueCallback(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef
) {
    guard let userData else {
        return
    }
    let player = Unmanaged<PCMStreamPlayer>.fromOpaque(userData).takeUnretainedValue()
    player.reclaimBuffer(buffer)
}

private final class PCMStreamPlayer: @unchecked Sendable {
    private static let bufferCount = 24
    private static let bufferDuration = 0.01
    private static let startDelay = 0.1
    private static let queueTargetDelay = 0.16
    private static let resetDelay = 0.45

    private let stateQueue = DispatchQueue(label: "MicListen.PCMStreamPlayer")
    private var audioQueue: AudioQueueRef?
    private var allBuffers: [AudioQueueBufferRef] = []
    private var freeBuffers: [AudioQueueBufferRef] = []
    private var freeBufferIDs = Set<Int>()
    private var queuedBufferFrames: [Int: Int] = [:]
    private var jitterBuffer: AdaptivePCMJitterBuffer?
    private var bytesPerFrame = 0
    private var playbackFrameFrames = 0
    private var startThresholdFrames = 0
    private var queueTargetFrames = 0
    private var resetThresholdFrames = 0
    private var queuedFrames = 0
    private var started = false
    private var stopped = true
    private var currentVolume: Float = 1

    func configure(sampleRate: Double, channels: Int, volume: Double) throws {
        let channelCount = max(1, min(channels, 2))
        let nextBytesPerFrame = channelCount * MemoryLayout<Int16>.size
        let nextPlaybackFrameFrames = max(Int((sampleRate * Self.bufferDuration).rounded()), 1)
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(nextBytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(nextBytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Int16>.size * 8),
            mReserved: 0
        )

        var nextQueue: AudioQueueRef?
        try checkAudioQueueStatus(
            AudioQueueNewOutput(
                &description,
                micListenAudioQueueCallback,
                Unmanaged.passUnretained(self).toOpaque(),
                nil,
                nil,
                0,
                &nextQueue
            ),
            operation: "create native audio output"
        )
        guard let nextQueue else {
            throw MicListenError.malformedResponse("The native audio queue could not be created.")
        }

        let clampedVolume = Float(min(max(volume, 0), 1))
        do {
            try checkAudioQueueStatus(
                AudioQueueSetParameter(nextQueue, kAudioQueueParam_Volume, clampedVolume),
                operation: "set native audio volume"
            )

            let nextJitterBuffer = try AdaptivePCMJitterBuffer(
                frameFrames: nextPlaybackFrameFrames,
                bytesPerFrame: nextBytesPerFrame
            )
            let bufferByteCapacity = nextPlaybackFrameFrames * nextBytesPerFrame
            var nextBuffers: [AudioQueueBufferRef] = []
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                try checkAudioQueueStatus(
                    AudioQueueAllocateBuffer(nextQueue, UInt32(bufferByteCapacity), &buffer),
                    operation: "allocate native audio buffer"
                )
                if let buffer {
                    nextBuffers.append(buffer)
                }
            }

            stateQueue.sync {
                stopLocked()
                audioQueue = nextQueue
                allBuffers = nextBuffers
                freeBuffers = nextBuffers
                freeBufferIDs = Set(nextBuffers.map(bufferID))
                queuedBufferFrames.removeAll()
                jitterBuffer = nextJitterBuffer
                bytesPerFrame = nextBytesPerFrame
                playbackFrameFrames = nextPlaybackFrameFrames
                startThresholdFrames = max(Int(sampleRate * Self.startDelay), 2)
                queueTargetFrames = max(Int(sampleRate * Self.queueTargetDelay), nextPlaybackFrameFrames)
                resetThresholdFrames = max(Int(sampleRate * Self.resetDelay), nextPlaybackFrameFrames)
                queuedFrames = 0
                started = false
                stopped = false
                currentVolume = clampedVolume
            }
        } catch {
            AudioQueueDispose(nextQueue, true)
            throw error
        }
    }

    func push(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        stateQueue.async { [data] in
            self.enqueue(data)
        }
    }

    func setVolume(_ volume: Double) {
        let clamped = Float(min(max(volume, 0), 1))
        stateQueue.async {
            self.currentVolume = clamped
            if let audioQueue = self.audioQueue {
                AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, clamped)
            }
        }
    }

    func stop() {
        stateQueue.sync {
            stopped = true
            stopLocked()
        }
    }

    func reclaimBuffer(_ buffer: AudioQueueBufferRef) {
        stateQueue.async {
            guard self.audioQueue != nil else {
                return
            }
            let id = self.bufferID(buffer)
            if let frames = self.queuedBufferFrames.removeValue(forKey: id) {
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
            self.returnBuffer(buffer)
            if let audioQueue = self.audioQueue {
                self.pumpQueue(audioQueue)
            }
            if self.queuedFrames == 0 {
                self.started = false
            }
        }
    }

    private func enqueue(_ data: Data) {
        guard !stopped,
              let audioQueue,
              let jitterBuffer,
              bytesPerFrame > 0 else {
            return
        }

        jitterBuffer.push(data)
        if queuedFrames > resetThresholdFrames {
            resetQueue(audioQueue)
            jitterBuffer.reset()
        }
        pumpQueue(audioQueue)
    }

    private func pumpQueue(_ audioQueue: AudioQueueRef) {
        guard let jitterBuffer, bytesPerFrame > 0, playbackFrameFrames > 0 else {
            return
        }

        while !stopped, queuedFrames < queueTargetFrames, let buffer = checkoutBuffer() {
            let shouldConcealMissingFrames = started
            guard let frameData = jitterBuffer.popFrame(
                allowConcealment: shouldConcealMissingFrames,
                queuedApplicationFrames: queuedFrames
            ) else {
                returnBuffer(buffer)
                break
            }

            let bytesToCopy = min(frameData.count, Int(buffer.pointee.mAudioDataBytesCapacity))
            frameData.withUnsafeBytes { frameBuffer in
                if let source = frameBuffer.baseAddress {
                    memcpy(buffer.pointee.mAudioData, source, bytesToCopy)
                }
            }
            buffer.pointee.mAudioDataByteSize = UInt32(bytesToCopy)

            let status = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
            guard status == noErr else {
                returnBuffer(buffer)
                return
            }

            let id = bufferID(buffer)
            let framesToCopy = bytesToCopy / bytesPerFrame
            queuedBufferFrames[id] = framesToCopy
            queuedFrames += framesToCopy
            if !started, queuedFrames >= startThresholdFrames {
                if AudioQueueStart(audioQueue, nil) == noErr {
                    started = true
                }
            }
        }
    }

    private func checkoutBuffer() -> AudioQueueBufferRef? {
        guard let buffer = freeBuffers.popLast() else {
            return nil
        }
        freeBufferIDs.remove(bufferID(buffer))
        return buffer
    }

    private func returnBuffer(_ buffer: AudioQueueBufferRef) {
        let id = bufferID(buffer)
        guard !freeBufferIDs.contains(id) else {
            return
        }
        freeBufferIDs.insert(id)
        freeBuffers.append(buffer)
    }

    private func resetQueue(_ audioQueue: AudioQueueRef) {
        AudioQueueReset(audioQueue)
        queuedFrames = 0
        started = false
        queuedBufferFrames.removeAll()
        freeBuffers = allBuffers
        freeBufferIDs = Set(allBuffers.map(bufferID))
    }

    private func stopLocked() {
        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
        }
        audioQueue = nil
        allBuffers.removeAll()
        freeBuffers.removeAll()
        freeBufferIDs.removeAll()
        queuedBufferFrames.removeAll()
        jitterBuffer = nil
        bytesPerFrame = 0
        playbackFrameFrames = 0
        queueTargetFrames = 0
        resetThresholdFrames = 0
        queuedFrames = 0
        started = false
    }

    private func bufferID(_ buffer: AudioQueueBufferRef) -> Int {
        Int(bitPattern: buffer)
    }

    private func checkAudioQueueStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MicListenError.network("Could not \(operation) (AudioQueue \(status)).")
        }
    }
}

private final class AdaptivePCMJitterBuffer {
    private enum SpeexJitter {
        static let ok: CInt = 0
        static let missing: CInt = 1
        static let insertion: CInt = 2
        static let getAvailableCount: CInt = 3
    }

    private let jitter: OpaquePointer
    private let frameFrames: Int
    private let frameByteCount: Int
    private let channelCount: Int
    private var inputCarry = Data()
    private var sourceTimestamp: UInt32 = 0
    private var sequence: UInt16 = 0
    private var bufferedFrames = 0
    private var lastSamples: [Int16]
    private var missingFrameStreak = 0

    init(frameFrames: Int, bytesPerFrame: Int) throws {
        guard frameFrames > 0, bytesPerFrame > 0 else {
            throw MicListenError.malformedResponse("The stream audio format is not supported.")
        }
        guard let jitter = jitter_buffer_init(CInt(frameFrames)) else {
            throw MicListenError.network("Could not create the adaptive audio jitter buffer.")
        }
        self.jitter = jitter
        self.frameFrames = frameFrames
        self.frameByteCount = frameFrames * bytesPerFrame
        let nextChannelCount = max(bytesPerFrame / MemoryLayout<Int16>.size, 1)
        self.channelCount = nextChannelCount
        self.lastSamples = Array(repeating: 0, count: nextChannelCount)
    }

    deinit {
        jitter_buffer_destroy(jitter)
    }

    func push(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        inputCarry.append(data)
        while inputCarry.count >= frameByteCount {
            let frame = Data(inputCarry.prefix(frameByteCount))
            inputCarry.removeFirst(frameByteCount)
            putFrame(frame)
        }
        refreshBufferedFrames()
    }

    func popFrame(allowConcealment: Bool, queuedApplicationFrames: Int) -> Data? {
        refreshBufferedFrames()
        guard allowConcealment || bufferedFrames >= frameFrames else {
            return nil
        }

        let remaining = UInt32(max(queuedApplicationFrames, 0))
        jitter_buffer_remaining_span(jitter, remaining)

        var output = [UInt8](repeating: 0, count: frameByteCount)
        var returnedLength = 0
        var status: CInt = SpeexJitter.missing
        output.withUnsafeMutableBytes { outputBuffer in
            guard let baseAddress = outputBuffer.bindMemory(to: CChar.self).baseAddress else {
                return
            }
            var packet = JitterBufferPacket(
                data: baseAddress,
                len: UInt32(frameByteCount),
                timestamp: 0,
                span: 0,
                sequence: 0,
                user_data: 0
            )
            var startOffset: Int32 = 0
            status = jitter_buffer_get(jitter, &packet, Int32(frameFrames), &startOffset)
            returnedLength = Int(packet.len)
        }
        jitter_buffer_tick(jitter)
        refreshBufferedFrames()

        switch status {
        case SpeexJitter.ok:
            missingFrameStreak = 0
            let frame = normalizedFrame(from: output, byteCount: returnedLength)
            rememberLastSamples(from: frame)
            return frame
        case SpeexJitter.missing, SpeexJitter.insertion:
            missingFrameStreak += 1
            return concealmentFrame()
        default:
            return nil
        }
    }

    func reset() {
        jitter_buffer_reset(jitter)
        inputCarry.removeAll()
        sourceTimestamp = 0
        sequence = 0
        bufferedFrames = 0
        lastSamples = Array(repeating: 0, count: channelCount)
        missingFrameStreak = 0
    }

    private func putFrame(_ frame: Data) {
        frame.withUnsafeBytes { frameBuffer in
            guard let baseAddress = frameBuffer.bindMemory(to: CChar.self).baseAddress else {
                return
            }
            var packet = JitterBufferPacket(
                data: UnsafeMutablePointer(mutating: baseAddress),
                len: UInt32(frame.count),
                timestamp: sourceTimestamp,
                span: UInt32(frameFrames),
                sequence: sequence,
                user_data: 0
            )
            jitter_buffer_put(jitter, &packet)
        }
        sourceTimestamp &+= UInt32(frameFrames)
        sequence &+= 1
    }

    private func normalizedFrame(from bytes: [UInt8], byteCount: Int) -> Data {
        let validByteCount = min(max(byteCount, 0), frameByteCount)
        var frame = Data(bytes.prefix(validByteCount))
        if frame.count < frameByteCount {
            frame.append(Data(repeating: 0, count: frameByteCount - frame.count))
        }
        return frame
    }

    private func concealmentFrame() -> Data {
        guard missingFrameStreak == 1, lastSamples.contains(where: { $0 != 0 }) else {
            lastSamples = Array(repeating: 0, count: channelCount)
            return Data(repeating: 0, count: frameByteCount)
        }

        var frame = Data(count: frameByteCount)
        frame.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frameIndex in 0..<frameFrames {
                let gain = Float(frameFrames - frameIndex) / Float(frameFrames)
                for channel in 0..<channelCount {
                    let sampleIndex = frameIndex * channelCount + channel
                    let byteIndex = sampleIndex * MemoryLayout<Int16>.size
                    let sample = Int16(clamping: Int(Float(lastSamples[channel]) * gain))
                    let littleEndian = UInt16(bitPattern: sample).littleEndian
                    bytes[byteIndex] = UInt8(truncatingIfNeeded: littleEndian)
                    bytes[byteIndex + 1] = UInt8(truncatingIfNeeded: littleEndian >> 8)
                }
            }
        }
        lastSamples = Array(repeating: 0, count: channelCount)
        return frame
    }

    private func rememberLastSamples(from frame: Data) {
        let requiredSampleCount = frameFrames * channelCount
        let bytesPerSample = MemoryLayout<Int16>.size
        guard frame.count >= requiredSampleCount * bytesPerSample else {
            return
        }

        frame.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let finalFrameStart = (frameFrames - 1) * channelCount
            for channel in 0..<channelCount {
                let byteIndex = (finalFrameStart + channel) * bytesPerSample
                let rawSample = UInt16(bytes[byteIndex]) | (UInt16(bytes[byteIndex + 1]) << 8)
                lastSamples[channel] = Int16(bitPattern: UInt16(littleEndian: rawSample))
            }
        }
    }

    private func refreshBufferedFrames() {
        var availablePacketCount: Int32 = 0
        jitter_buffer_ctl(jitter, SpeexJitter.getAvailableCount, &availablePacketCount)
        bufferedFrames = max(0, Int(availablePacketCount) * frameFrames)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
