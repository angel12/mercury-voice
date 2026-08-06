import SwiftUI

@main
struct HermesVoiceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                #if os(macOS)
                    .frame(minWidth: 480, minHeight: 560)
                #endif
        }
        #if os(macOS)
            .windowResizability(.contentSize)
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let conversation = model.conversation {
                ConversationView(controller: conversation)
            } else if model.isConnected {
                BrowseView()
            } else {
                ConnectView()
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
