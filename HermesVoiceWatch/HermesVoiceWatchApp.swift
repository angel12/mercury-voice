import SwiftUI

@main
struct HermesVoiceWatchApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
        }
    }
}

struct WatchRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let conversation = model.conversation {
                WatchConversationView(controller: conversation)
            } else if model.isConnected {
                WatchBrowseView()
            } else {
                WatchConnectView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.appBecameActive()
            }
        }
        .task { await model.autoConnectOnLaunch() }
    }
}
