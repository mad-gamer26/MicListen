import SwiftUI

struct EndpointDetailView: View {
    @EnvironmentObject private var model: AppModel

    let endpoint: SavedEndpoint

    @State private var editEndpoint: SavedEndpoint?
    @State private var passwordRequest: PasswordRequest?
    @State private var confirmingDelete = false

    var body: some View {
        let currentEndpoint = model.endpoint(id: endpoint.id) ?? endpoint
        let state = model.state(for: endpoint.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EndpointHeader(endpoint: currentEndpoint, state: state) {
                    Task { await model.refresh(endpointID: currentEndpoint.id) }
                } passwordAction: {
                    passwordRequest = model.endpointPasswordRequest(for: currentEndpoint)
                }

                content(endpoint: currentEndpoint, state: state)
            }
            .padding()
            .frame(maxWidth: 920, alignment: .leading)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(currentEndpoint.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await model.refresh(endpointID: currentEndpoint.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")

                Button {
                    editEndpoint = currentEndpoint
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Edit")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
            }
        }
        .sheet(item: $editEndpoint) { endpoint in
            EditEndpointView(endpoint: endpoint)
        }
        .sheet(item: $passwordRequest) { request in
            PasswordPromptView(request: request)
        }
        .confirmationDialog("Delete Endpoint", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.deleteEndpoint(currentEndpoint)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func content(endpoint: SavedEndpoint, state: EndpointLoadState) -> some View {
        if let resolution = state.resolution, state.status == .ready || state.status == .loading {
            EndpointResolutionView(
                endpoint: endpoint,
                resolution: resolution,
                passwordRequest: $passwordRequest
            )
        } else {
            switch state.status {
            case .idle, .loading:
                ProgressBlock(title: "Checking Endpoint")
            case .needsPassword:
                ProblemBlock(
                    title: "Password Required",
                    message: state.message ?? "MicListen requires a password.",
                    systemImage: "lock.fill",
                    actionTitle: "Enter Password"
                ) {
                    passwordRequest = model.endpointPasswordRequest(for: endpoint)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .failed:
                ProblemBlock(
                    title: "Endpoint Unavailable",
                    message: state.message ?? "The endpoint could not be reached.",
                    systemImage: "exclamationmark.triangle.fill",
                    actionTitle: "Retry"
                ) {
                    Task { await model.refresh(endpointID: endpoint.id) }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .ready:
                EmptyView()
            }
        }
    }
}

private struct EndpointHeader: View {
    let endpoint: SavedEndpoint
    let state: EndpointLoadState
    let refreshAction: () -> Void
    let passwordAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(kindColor.opacity(0.16))
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(kindColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 8) {
                    Text(endpoint.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(endpoint.baseURLString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        StatusBadge(kind.title, systemImage: kind.systemImage, color: kindColor)
                        StatusBadge(statusTitle, systemImage: statusImage, color: statusColor)
                    }
                }

                Spacer(minLength: 0)
            }

            if let resolution = state.resolution {
                HStack(spacing: 18) {
                    HeaderMetric(title: "Version", value: resolution.health.version ?? "Unknown")
                    HeaderMetric(title: "Authentication", value: resolution.health.authentication == true ? "Enabled" : "Off")
                    if resolution.kind == .relay {
                        HeaderMetric(title: "Streamers", value: "\(resolution.health.connectedStreamers ?? resolution.targets.count)")
                    } else {
                        HeaderMetric(title: "Devices", value: "\(resolution.targets.first?.devices.count ?? 0)")
                    }
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Button(action: refreshAction) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(action: passwordAction) {
                    Label("Password", systemImage: "key")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var kind: EndpointKind {
        state.resolution?.kind ?? endpoint.lastResolvedKind
    }

    private var kindColor: Color {
        kind == .relay ? .indigo : (kind == .streamer ? .mint : .secondary)
    }

    private var statusTitle: String {
        switch state.status {
        case .idle: return "Idle"
        case .loading: return "Refreshing"
        case .ready: return "Online"
        case .needsPassword: return "Locked"
        case .failed: return "Offline"
        }
    }

    private var statusImage: String {
        switch state.status {
        case .idle: return "circle"
        case .loading: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .needsPassword: return "lock.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .idle: return .secondary
        case .loading: return .blue
        case .ready: return .green
        case .needsPassword: return .orange
        case .failed: return .red
        }
    }
}

private struct EndpointResolutionView: View {
    let endpoint: SavedEndpoint
    let resolution: EndpointResolution
    @Binding var passwordRequest: PasswordRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = resolution.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            if resolution.targets.isEmpty {
                ProblemBlock(
                    title: resolution.kind == .relay ? "No Streamers" : "No Devices",
                    message: resolution.kind == .relay ? "The relay is online." : "The streamer is online.",
                    systemImage: resolution.kind == .relay ? "point.3.connected.trianglepath.dotted" : "speaker.slash",
                    actionTitle: nil,
                    action: nil
                )
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ForEach(resolution.targets) { target in
                    StreamerTargetView(target: target) {
                        passwordRequest = PasswordRequest(
                            title: "Streamer Password",
                            message: target.displayName,
                            scope: .streamer(endpointID: endpoint.id, name: target.name)
                        )
                    }
                }
            }
        }
    }
}

private struct ProgressBlock: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
