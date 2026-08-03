import SwiftUI

struct EndpointDetailView: View {
    @EnvironmentObject private var model: AppModel

    let endpoint: SavedEndpoint

    @State private var passwordRequest: PasswordRequest?
    @State private var selectedStreamerID: String?

    var body: some View {
        let currentEndpoint = model.endpoint(id: endpoint.id) ?? endpoint
        let state = model.state(for: endpoint.id)

        content(endpoint: currentEndpoint, state: state)
            .navigationTitle(currentEndpoint.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(WebTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refresh(endpointID: currentEndpoint.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .sheet(item: $passwordRequest) { request in
                PasswordPromptView(request: request)
            }
            .onChange(of: endpoint.id) { _, _ in
                selectedStreamerID = nil
            }
            .onChange(of: model.endpointOpenRequest) { _, request in
                guard request?.endpointID == endpoint.id else {
                    return
                }
                selectedStreamerID = nil
            }
    }

    @ViewBuilder
    private func content(endpoint: SavedEndpoint, state: EndpointLoadState) -> some View {
        if let resolution = state.resolution, state.status == .ready || state.status == .loading {
            if resolution.kind == .relay {
                if let selectedStreamerID,
                   let target = resolution.targets.first(where: { $0.id == selectedStreamerID }) {
                    StreamerInterfaceView(
                        endpoint: endpoint,
                        targetID: target.id,
                        fallbackTarget: target,
                        refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                        passwordAction: {
                            passwordRequest = PasswordRequest(
                                title: "Streamer Password",
                                message: target.displayName,
                                scope: .streamer(endpointID: endpoint.id, name: target.name)
                            )
                        },
                        relayBackAction: { self.selectedStreamerID = nil }
                    )
                } else {
                    RelayInterfaceView(
                        endpoint: endpoint,
                        resolution: resolution,
                        isRefreshing: state.isLoading,
                        passwordRequest: $passwordRequest
                    ) { target in
                        selectedStreamerID = target.id
                    }
                }
            } else if let target = resolution.targets.first {
                StreamerInterfaceView(
                    endpoint: endpoint,
                    targetID: target.id,
                    fallbackTarget: target,
                    refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                    passwordAction: { passwordRequest = model.endpointPasswordRequest(for: endpoint) }
                )
            } else {
                EndpointStatePage(
                    title: "MicListen",
                    subtitle: "Hear microphones and system audio from this computer, right in your browser.",
                    message: "No audio devices available",
                    state: .empty,
                    refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                    passwordAction: { passwordRequest = model.endpointPasswordRequest(for: endpoint) }
                )
            }
        } else {
            switch state.status {
            case .idle, .loading:
                EndpointStatePage(
                    title: endpoint.lastResolvedKind == .relay ? "MicListen Relay" : "MicListen",
                    subtitle: endpoint.lastResolvedKind == .relay ? "Select a connected streamer." : "Hear microphones and system audio from this computer, right in your browser.",
                    message: "Checking endpoint",
                    state: .loading,
                    refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                    passwordAction: { passwordRequest = model.endpointPasswordRequest(for: endpoint) }
                )
            case .needsPassword:
                EndpointStatePage(
                    title: endpoint.lastResolvedKind == .relay || state.message?.lowercased().contains("relay") == true ? "MicListen Relay" : "MicListen",
                    subtitle: endpoint.lastResolvedKind == .relay || state.message?.lowercased().contains("relay") == true ? "Select a connected streamer." : "Hear microphones and system audio from this computer, right in your browser.",
                    message: state.message ?? "MicListen requires a password.",
                    state: .locked,
                    refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                    passwordAction: { passwordRequest = model.endpointPasswordRequest(for: endpoint) }
                )
            case .failed:
                EndpointStatePage(
                    title: endpoint.lastResolvedKind == .relay ? "MicListen Relay" : "MicListen",
                    subtitle: endpoint.lastResolvedKind == .relay ? "Select a connected streamer." : "Hear microphones and system audio from this computer, right in your browser.",
                    message: state.message ?? "The endpoint could not be reached.",
                    state: .failed,
                    refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                    passwordAction: { passwordRequest = model.endpointPasswordRequest(for: endpoint) }
                )
            case .ready:
                EndpointStatePage(
                    title: "MicListen",
                    subtitle: "Hear microphones and system audio from this computer, right in your browser.",
                    message: "No audio devices available",
                    state: .empty,
                    refreshAction: { Task { await model.refresh(endpointID: endpoint.id) } },
                    passwordAction: { passwordRequest = model.endpointPasswordRequest(for: endpoint) }
                )
            }
        }
    }
}

private struct RelayInterfaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let endpoint: SavedEndpoint
    let resolution: EndpointResolution
    let isRefreshing: Bool
    @Binding var passwordRequest: PasswordRequest?
    let selectTarget: (StreamerTarget) -> Void

    var body: some View {
        WebPage {
            WebHero(title: "MicListen Relay", subtitle: "Select a connected streamer.") {
                HStack(spacing: 9) {
                    WebIconButton(systemImage: "arrow.clockwise", title: "Refresh streamers") {
                        Task { await model.refresh(endpointID: endpoint.id) }
                    }
                    WebActionButton("Password", systemImage: "key") {
                        passwordRequest = model.endpointPasswordRequest(for: endpoint)
                    }
                }
            }

            RelayToolbar(count: resolution.targets.count, isRefreshing: isRefreshing)
                .padding(.top, 30)
                .padding(.bottom, 20)

            if let message = resolution.message {
                WebNotice(message: message)
                    .padding(.bottom, 18)
            }

            if resolution.targets.isEmpty {
                WebEmptyState("No streamers are currently connected.")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(resolution.targets) { target in
                        RelayStreamerCard(endpoint: endpoint, target: target) {
                            passwordRequest = PasswordRequest(
                                title: "Streamer Password",
                                message: target.displayName,
                                scope: .streamer(endpointID: endpoint.id, name: target.name)
                            )
                        } selectAction: {
                            selectTarget(target)
                        }
                    }
                }
            }

            Text("Version \(resolution.health.version ?? "unknown")")
                .font(.system(size: 12))
                .foregroundStyle(WebTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
        }
    }

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .compact ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }
}

private struct RelayToolbar: View {
    let count: Int
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                Text("Show")
                    .font(.system(size: 13))
                    .foregroundStyle(WebTheme.muted)
                Text("Connected")
                    .font(.system(size: 15))
                    .foregroundStyle(WebTheme.text)
                    .frame(minWidth: 148, minHeight: 39)
                    .background(WebTheme.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(WebTheme.line, lineWidth: 1)
                    )
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView()
                        .tint(WebTheme.accent)
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(count == 0 ? "No streamers connected" : "\(count) streamer\(count == 1 ? "" : "s") connected")
                    .font(.system(size: 13))
                    .foregroundStyle(WebTheme.muted)
            }
        }
    }
}

private struct RelayStreamerCard: View {
    @EnvironmentObject private var model: AppModel

    let endpoint: SavedEndpoint
    let target: StreamerTarget
    let passwordAction: () -> Void
    let selectAction: () -> Void

    var body: some View {
        if target.requiresPassword {
            Button(action: passwordAction) {
                cardContent(icon: "lock.fill", status: "Locked", statusColor: .orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enter password for \(target.displayName)")
        } else if target.problem != nil {
            cardContent(icon: "exclamationmark.triangle.fill", status: "Unavailable", statusColor: WebTheme.danger)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(target.displayName)
                .accessibilityValue(target.problem ?? "Unavailable")
        } else {
            Button(action: selectAction) {
                cardContent(icon: "desktopcomputer.and.macbook", status: target.statusText, statusColor: WebTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(target.displayName)
            .accessibilityValue("\(target.devices.count) device\(target.devices.count == 1 ? "" : "s")")
        }
    }

    private func cardContent(icon: String, status: String, statusColor: Color) -> some View {
        let live = target.problem == nil && !target.requiresPassword

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(WebTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(Color(red: 0.094, green: 0.220, blue: 0.188), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(target.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(WebTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: statusColor.opacity(live ? 0.9 : 0), radius: 5)
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(WebTheme.muted)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: target.requiresPassword ? "key.fill" : "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(target.requiresPassword ? WebTheme.background : WebTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(target.requiresPassword ? WebTheme.accent : Color.clear)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }

            Text(target.problem ?? target.baseURL.absoluteString)
                .font(.system(size: 12))
                .foregroundStyle(WebTheme.muted)
                .lineLimit(2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.071, green: 0.153, blue: 0.141).opacity(0.94),
                    Color(red: 0.051, green: 0.114, blue: 0.106).opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(target.requiresPassword ? Color.orange.opacity(0.55) : WebTheme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 14)
    }
}

private struct EndpointStatePage: View {
    enum StateKind {
        case loading
        case locked
        case failed
        case empty
    }

    let title: String
    let subtitle: String
    let message: String
    let state: StateKind
    let refreshAction: () -> Void
    let passwordAction: () -> Void

    var body: some View {
        WebPage {
            WebHero(title: title, subtitle: subtitle) {
                HStack(spacing: 9) {
                    WebIconButton(systemImage: "arrow.clockwise", title: "Refresh", action: refreshAction)
                    WebActionButton("Password", systemImage: "key", action: passwordAction)
                }
            }
            .padding(.bottom, 30)

            switch state {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(WebTheme.accent)
                    Text(message)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WebTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            case .locked:
                WebLockedState(title: "Password Required", message: message, actionTitle: "Enter Password", action: passwordAction)
            case .failed:
                WebNotice(message: message)
                    .padding(.bottom, 18)
                WebEmptyState("No audio devices available")
            case .empty:
                WebEmptyState(message)
            }
        }
    }
}
