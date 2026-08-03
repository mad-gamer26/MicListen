import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddEndpoint = false
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            EndpointSidebarView(showingAddEndpoint: $showingAddEndpoint)
        } detail: {
            if let endpoint = model.endpoint(id: model.selectedEndpointID) {
                EndpointDetailView(endpoint: endpoint)
            } else {
                EmptyEndpointLibraryView {
                    showingAddEndpoint = true
                }
            }
        }
        .tint(WebTheme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingAddEndpoint) {
            AddEndpointView()
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: model.selectedEndpointID) { _, endpointID in
            guard let endpointID else {
                return
            }
            preferredCompactColumn = .detail
            guard model.state(for: endpointID).status == .idle else {
                return
            }
            Task {
                await model.refresh(endpointID: endpointID)
            }
        }
        .onChange(of: preferredCompactColumn) { _, column in
            if column == .sidebar, model.selectedEndpointID != nil {
                model.closeSelectedEndpoint()
            }
        }
    }
}

struct EmptyEndpointLibraryView: View {
    let addAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("MicListen", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Add a relay or streamer.")
        } actions: {
            Button(action: addAction) {
                Label("Add Endpoint", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
