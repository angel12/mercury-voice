import SwiftUI

@main
struct HermesVoiceApp: App {
    @State private var model = AppModel()
    @AppStorage(ThemePreference.key) private var theme = ThemePreference.system
    #if os(macOS)
        @State private var muteHotkey = MuteHotkeyManager()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(theme.colorScheme)
                #if os(macOS)
                    .frame(minWidth: 480, minHeight: 560)
                    .onAppear {
                        muteHotkey.onToggleMute = {
                            model.conversation?.toggleMute()
                        }
                    }
                #endif
        }
        #if os(macOS)
            .windowResizability(.contentSize)
            .commands {
                ConversationCommands(model: model, hotkey: muteHotkey)
            }
        #endif

        #if os(macOS)
            Settings {
                // The Settings scene is its own window; the WindowGroup's
                // color scheme doesn't reach it.
                SettingsView(hotkey: muteHotkey)
                    .preferredColorScheme(theme.colorScheme)
            }
        #endif
    }
}

#if os(macOS)
    /// Menu commands for the live conversation. The mute item carries the
    /// user-configured key equivalent; in system-wide mode the Carbon
    /// registration consumes the key first, so the equivalent doubles as a
    /// menu hint without ever firing twice.
    struct ConversationCommands: Commands {
        let model: AppModel
        let hotkey: MuteHotkeyManager

        var body: some Commands {
            CommandMenu("Conversation") {
                Group {
                    muteItem
                    Button("End Turn") { model.conversation?.endTurnNow() }
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Stop Speaking") { model.conversation?.stopSpeech() }
                        .keyboardShortcut(".", modifiers: .command)
                }
                .disabled(model.conversation == nil)
            }
        }

        @ViewBuilder private var muteItem: some View {
            let muted = model.conversation?.voiceState.muted == true
            let mute = Button(muted ? "Unmute Microphone" : "Mute Microphone") {
                model.conversation?.toggleMute()
            }
            if hotkey.enabled, let key = hotkey.combo.keyEquivalent {
                mute.keyboardShortcut(key, modifiers: hotkey.combo.eventModifiers)
            } else {
                mute
            }
        }
    }
#endif

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
