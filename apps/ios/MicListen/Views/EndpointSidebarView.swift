import SwiftUI

struct EndpointSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingAddEndpoint: Bool
    @State private var editEndpoint: SavedEndpoint?

    var body: some View {
        List(selection: selection) {
            ForEach(model.endpoints) { endpoint in
                NavigationLink(value: endpoint.id) {
                    EndpointSidebarRow(endpoint: endpoint)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    model.openEndpoint(endpoint.id)
                })
                .contextMenu {
                    Button {
                        editEndpoint = endpoint
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        model.deleteEndpoint(endpoint)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: Text("Edit")) {
                    editEndpoint = endpoint
                }
                .accessibilityAction(named: Text("Delete")) {
                    model.deleteEndpoint(endpoint)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WebTheme.background)
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
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Add Endpoint")
            }
        }
        .sheet(item: $editEndpoint) { endpoint in
            EditEndpointView(endpoint: endpoint)
        }
    }

    private var selection: Binding<UUID?> {
        Binding {
            model.selectedEndpointID
        } set: { endpointID in
            if let endpointID {
                model.openEndpoint(endpointID)
            } else {
                model.selectedEndpointID = nil
            }
        }
    }
}

private struct EndpointSidebarRow: View {
    let endpoint: SavedEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(endpoint.displayName)
                .font(.headline)
                .foregroundStyle(WebTheme.text)
                .lineLimit(1)
            Text(endpoint.baseURLString)
                .font(.caption)
                .foregroundStyle(WebTheme.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(endpoint.displayName)
        .accessibilityValue(endpoint.baseURLString)
    }
}
