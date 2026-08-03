import SwiftUI

struct EndpointSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingAddEndpoint: Bool

    var body: some View {
        List(selection: $model.selectedEndpointID) {
            ForEach(model.endpoints) { endpoint in
                NavigationLink(value: endpoint.id) {
                    EndpointSidebarRow(endpoint: endpoint, state: model.state(for: endpoint.id))
                }
                .contextMenu {
                    Button {
                        Task { await model.refresh(endpointID: endpoint.id) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        model.deleteEndpoint(endpoint)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("MicListen")
        .overlay {
            if model.endpoints.isEmpty {
                ContentUnavailableView {
                    Label("No Endpoints", systemImage: "network.slash")
                } description: {
                    Text("Add a relay or streamer.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddEndpoint = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Endpoint")
            }
        }
    }
}

private struct EndpointSidebarRow: View {
    let endpoint: SavedEndpoint
    let state: EndpointLoadState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.16))
                Image(systemName: kind.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if state.status == .needsPassword {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
            } else if state.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var kind: EndpointKind {
        state.resolution?.kind ?? endpoint.lastResolvedKind
    }

    private var iconColor: Color {
        switch state.status {
        case .failed:
            return .red
        case .needsPassword:
            return .orange
        case .loading:
            return .blue
        case .ready:
            return kind == .relay ? .indigo : .mint
        case .idle:
            return .secondary
        }
    }

    private var subtitle: String {
        if let message = state.message, state.status != .ready {
            return message
        }
        if let resolution = state.resolution {
            if resolution.kind == .relay {
                return "\(resolution.targets.count) streamer\(resolution.targets.count == 1 ? "" : "s")"
            }
            return resolution.targets.first?.statusText ?? resolution.kind.title
        }
        return endpoint.baseURLString
    }
}
