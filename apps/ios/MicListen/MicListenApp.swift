import SwiftUI

@main
struct MicListenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.playback)
        }
    }
}
