import SwiftUI

private enum DeviceKindFilter: String, CaseIterable, Identifiable {
    case all
    case input
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .input: return "Inputs"
        case .output: return "Outputs"
        }
    }
}

struct StreamerInterfaceView: View {
    @EnvironmentObject private var model: AppModel

    let endpoint: SavedEndpoint
    let targetID: String
    let fallbackTarget: StreamerTarget
    let refreshAction: () -> Void
    let passwordAction: () -> Void

    @State private var filter: DeviceKindFilter = .all

    var body: some View {
        let target = resolvedTarget

        WebPage {
            WebHero(
                title: "MicListen",
                subtitle: "Hear microphones and system audio from this computer, right in your browser."
            ) {
                HStack(spacing: 9) {
                    WebIconButton(systemImage: "arrow.clockwise", title: "Refresh devices", action: refreshAction)
                    WebActionButton("Password", systemImage: "key", action: passwordAction)
                }
            }

            StreamerToolbar(
                filter: $filter,
                target: target,
                connectionNote: connectionNote(for: target)
            )
            .padding(.top, 30)
            .padding(.bottom, 20)

            if target.requiresPassword {
                WebLockedState(
                    title: "Streamer Locked",
                    message: target.problem ?? "Enter the streamer password to show audio devices.",
                    actionTitle: "Enter Password",
                    action: passwordAction
                )
            } else if let problem = target.problem {
                WebNotice(message: problem)
                    .padding(.bottom, 18)
                WebEmptyState("No audio devices available")
            } else if filteredDevices(for: target).isEmpty {
                WebEmptyState(emptyMessage(for: target))
            } else {
                DeviceGrid(target: target, filter: filter)
            }

            Text("Version \(target.health?.version ?? "unknown")")
                .font(.system(size: 12))
                .foregroundStyle(WebTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        }
        .navigationTitle(target.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(WebTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var resolvedTarget: StreamerTarget {
        model.state(for: endpoint.id)
            .resolution?
            .targets
            .first { $0.id == targetID } ?? fallbackTarget
    }

    private func filteredDevices(for target: StreamerTarget) -> [AudioDevice] {
        switch filter {
        case .all:
            return target.devices
        case .input:
            return target.devices.filter { $0.kind == "input" }
        case .output:
            return target.devices.filter { $0.kind == "output" }
        }
    }

    private func connectionNote(for target: StreamerTarget) -> String {
        let active = target.devices.filter { model.playback.isPlaying(target: target, device: $0) }.count
        if active == 0 {
            return "Select a device to begin listening"
        }
        return "Listening to \(active) device\(active == 1 ? "" : "s")"
    }

    private func emptyMessage(for target: StreamerTarget) -> String {
        if let error = target.health?.audioError, !error.isEmpty {
            return error
        }
        switch filter {
        case .all:
            return "No audio devices available"
        case .input:
            return "No input devices found"
        case .output:
            return "No output devices found"
        }
    }
}

private struct StreamerToolbar: View {
    @Binding var filter: DeviceKindFilter
    let target: StreamerTarget
    let connectionNote: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 9) {
                Text("Show")
                    .font(.system(size: 13))
                    .foregroundStyle(WebTheme.muted)

                Picker("Show", selection: $filter) {
                    ForEach(DeviceKindFilter.allCases) { option in
                        Text(optionTitle(option))
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(WebTheme.text)
                .frame(minWidth: 148, minHeight: 39)
                .background(WebTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(WebTheme.line, lineWidth: 1)
                )
            }

            Spacer(minLength: 12)

            Text(connectionNote)
                .font(.system(size: 13))
                .foregroundStyle(WebTheme.muted)
                .multilineTextAlignment(.trailing)
        }
    }

    private func optionTitle(_ option: DeviceKindFilter) -> String {
        switch option {
        case .all:
            return "All"
        case .input:
            return "Inputs (\(target.devices.filter { $0.kind == "input" }.count))"
        case .output:
            return "Outputs (\(target.devices.filter { $0.kind == "output" }.count))"
        }
    }
}

private struct DeviceGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let target: StreamerTarget
    let filter: DeviceKindFilter

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            if filter == .all {
                DeviceSection(title: "Inputs", devices: target.devices.filter { $0.kind == "input" }, target: target, columnSpan: columns.count)
                DeviceSection(title: "Outputs", devices: target.devices.filter { $0.kind == "output" }, target: target, columnSpan: columns.count)
            } else {
                ForEach(filteredDevices) { device in
                    WebDeviceCard(target: target, device: device)
                }
            }
        }
    }

    private var filteredDevices: [AudioDevice] {
        target.devices.filter { $0.kind == filter.rawValue }
    }

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .compact ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }
}

private struct DeviceSection: View {
    let title: String
    let devices: [AudioDevice]
    let target: StreamerTarget
    let columnSpan: Int

    var body: some View {
        if !devices.isEmpty {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(WebTheme.text)
                .gridCellColumns(columnSpan)
                .padding(.top, title == "Inputs" ? 0 : 8)
                .padding(.bottom, -3)

            ForEach(devices) { device in
                WebDeviceCard(target: target, device: device)
            }
        } else {
            Text("No \(title.lowercased()) devices found")
                .font(.system(size: 15))
                .foregroundStyle(WebTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(WebTheme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                )
                .gridCellColumns(columnSpan)
        }
    }
}

private struct WebDeviceCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: AudioPlaybackController

    let target: StreamerTarget
    let device: AudioDevice

    var body: some View {
        let sessionID = playback.sessionID(target: target, device: device)
        let session = playback.session(for: target, device: device)
        let active = session?.status.isActive == true

        VStack(spacing: 0) {
            HStack(spacing: 13) {
                WebDeviceIcon(kind: device.kind)

                VStack(alignment: .leading, spacing: 5) {
                    Text(device.cleanName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(WebTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(active ? WebTheme.accent : Color(red: 0.294, green: 0.380, blue: 0.361))
                            .frame(width: 7, height: 7)
                            .shadow(color: active ? WebTheme.accent.opacity(0.9) : .clear, radius: 5)
                            .accessibilityHidden(true)
                        Text(statusText(session: session))
                            .font(.system(size: 11))
                            .foregroundStyle(WebTheme.muted)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(device.cleanName)
                .accessibilityValue(deviceAccessibilityValue(session: session))

                Spacer(minLength: 8)

                Button {
                    model.togglePlayback(target: target, device: device)
                } label: {
                    Image(systemName: active ? "stop.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(active ? Color(red: 0.024, green: 0.129, blue: 0.094) : Color(red: 0.024, green: 0.129, blue: 0.094))
                        .frame(width: 42, height: 42)
                        .background(active ? Color(red: 0.898, green: 0.949, blue: 0.929) : WebTheme.accent)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(active ? "Stop listening to \(device.cleanName)" : "Start listening to \(device.cleanName)")
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(WebTheme.muted)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: { playback.volume(sessionID: sessionID) },
                        set: { playback.setVolume($0, sessionID: sessionID) }
                    ),
                    in: 0...1
                )
                .tint(WebTheme.accent)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(playback.volume(sessionID: sessionID) * 100)) percent")

                Text("\(Int(playback.volume(sessionID: sessionID) * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(WebTheme.muted)
                    .frame(width: 35, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.top, 15)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(red: 0.129, green: 0.227, blue: 0.208))
                    .frame(height: 1)
            }
            .padding(.top, 15)
        }
        .padding(20)
        .background(cardBackground(active: active))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(active ? Color(red: 0.192, green: 0.588, blue: 0.431) : WebTheme.line, lineWidth: 1)
        )
        .shadow(color: active ? Color(red: 0.051, green: 0.482, blue: 0.325).opacity(0.14) : .black.opacity(0.16), radius: 18, x: 0, y: 14)
    }

    private func cardBackground(active: Bool) -> LinearGradient {
        LinearGradient(
            colors: [
                active ? Color(red: 0.071, green: 0.204, blue: 0.165) : Color(red: 0.071, green: 0.153, blue: 0.141).opacity(0.94),
                Color(red: 0.051, green: 0.114, blue: 0.106).opacity(0.94)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func statusText(session: PlaybackSession?) -> String {
        session?.status.title ?? "Ready"
    }

    private func deviceAccessibilityValue(session: PlaybackSession?) -> String {
        let defaultText = device.isDefault ? ", Default" : ""
        return "\(device.kindTitle)\(defaultText), \(statusText(session: session)), \(device.channels) channels, \(device.sampleRate) hertz, \(device.hostAPI)"
    }
}

private struct WebDeviceIcon: View {
    let kind: String

    var body: some View {
        Image(systemName: kind == "output" ? "headphones" : "mic")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(WebTheme.accent)
            .frame(width: 42, height: 42)
            .background(Color(red: 0.094, green: 0.220, blue: 0.188), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct WebEmptyState: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundStyle(WebTheme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
            .padding(.horizontal, 20)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(WebTheme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            )
    }
}

struct WebLockedState: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(WebTheme.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(WebTheme.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(WebTheme.muted)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Label(actionTitle, systemImage: "key")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(WebTheme.accent)
            .foregroundStyle(Color(red: 0.024, green: 0.129, blue: 0.094))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.071, green: 0.153, blue: 0.141), Color(red: 0.051, green: 0.114, blue: 0.106)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(WebTheme.line, lineWidth: 1)
        )
    }
}
