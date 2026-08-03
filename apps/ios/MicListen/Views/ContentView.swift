import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddEndpoint = false

    var body: some View {
        NavigationSplitView {
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
        .tint(.mint)
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
        .task {
            await model.refreshAllIfNeeded()
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
