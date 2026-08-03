import SwiftUI

struct StreamerTargetView: View {
    let target: StreamerTarget
    let passwordAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "desktopcomputer.and.macbook")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(target.requiresPassword ? .orange : .mint)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(target.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                StatusBadge(
                    target.requiresPassword ? "Locked" : target.statusText,
                    systemImage: target.requiresPassword ? "lock.fill" : "checkmark.circle.fill",
                    color: target.requiresPassword ? .orange : (target.problem == nil ? .green : .red)
                )
            }

            if target.requiresPassword {
                ProblemBlock(
                    title: "Streamer Locked",
                    message: target.problem ?? "This streamer requires a password.",
                    systemImage: "lock.fill",
                    actionTitle: "Enter Password",
                    action: passwordAction
                )
            } else if let problem = target.problem {
                ProblemBlock(
                    title: "Streamer Unavailable",
                    message: problem,
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: nil,
                    action: nil
                )
            } else if target.devices.isEmpty {
                ProblemBlock(
                    title: "No Audio Devices",
                    message: target.health?.audioError ?? "MicListen did not report any capture devices.",
                    systemImage: "speaker.slash",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                DeviceGroupsView(target: target)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DeviceGroupsView: View {
    let target: StreamerTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let inputs = target.devices.filter { $0.kind == "input" }
            let outputs = target.devices.filter { $0.kind == "output" }

            if !inputs.isEmpty {
                DeviceGroup(title: "Inputs", devices: inputs, target: target)
            }
            if !outputs.isEmpty {
                DeviceGroup(title: "Outputs", devices: outputs, target: target)
            }
        }
    }
}

private struct DeviceGroup: View {
    let title: String
    let devices: [AudioDevice]
    let target: StreamerTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                ForEach(devices) { device in
                    DeviceRow(target: target, device: device)
                    if device.id != devices.last?.id {
                        Divider()
                            .padding(.leading, 46)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: AudioPlaybackController

    let target: StreamerTarget
    let device: AudioDevice

    var body: some View {
        let sessionID = playback.sessionID(target: target, device: device)
        let session = playback.session(for: target, device: device)
        let active = session?.status.isActive == true

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: device.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(device.kind == "output" ? .indigo : .mint)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.cleanName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if device.isDefault {
                            StatusBadge("Default", color: .blue)
                        }
                    }
                    Text("\(device.channels) ch · \(device.sampleRate) Hz · \(device.hostAPI)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    model.togglePlayback(target: target, device: device)
                } label: {
                    Image(systemName: active ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(active ? .red : .mint)
                .accessibilityLabel(active ? "Stop \(device.cleanName)" : "Play \(device.cleanName)")
            }

            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusBadge(session.status.title, systemImage: session.status.systemImage, color: statusColor(session.status))
                        if case .failed(let message) = session.status {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else if let message = session.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.1")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { playback.volume(sessionID: sessionID) },
                                set: { playback.setVolume($0, sessionID: sessionID) }
                            ),
                            in: 0...1
                        )
                        Text("\(Int(playback.volume(sessionID: sessionID) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .padding(.leading, 46)
            }
        }
        .padding(12)
    }

    private func statusColor(_ status: PlaybackStatus) -> Color {
        switch status {
        case .connecting:
            return .blue
        case .live:
            return .green
        case .buffering:
            return .orange
        case .paused:
            return .secondary
        case .failed:
            return .red
        }
    }
}
