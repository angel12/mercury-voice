#if os(macOS)
    import Carbon.HIToolbox
    import SwiftUI
    import VoiceEngine

    /// App settings (⌘,): audio devices and the microphone mute shortcut.
    struct SettingsView: View {
        @Bindable var hotkey: MuteHotkeyManager
        var devices = AudioDeviceCatalog.shared
        @AppStorage(CuePreference.key) private var cuesEnabled = true

        var body: some View {
            Form {
                Section("Audio Devices") {
                    AudioInputPicker(devices: devices)
                    AudioOutputPicker(devices: devices)
                    Text(
                        "A microphone change applies immediately, even mid-conversation. An output change applies from the next spoken reply."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Sounds") {
                    Toggle("Conversation cues", isOn: $cuesEnabled)
                    Text(
                        "A short blip confirms your speech was captured; a soft tick every few seconds means the agent is still thinking."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Microphone") {
                    Toggle("Mute/unmute shortcut", isOn: $hotkey.enabled)
                    LabeledContent("Shortcut") {
                        HotkeyRecorder(combo: $hotkey.combo)
                    }
                    .disabled(!hotkey.enabled)
                    Toggle("Use shortcut system-wide", isOn: $hotkey.isGlobal)
                        .disabled(!hotkey.enabled)
                    Text(
                        hotkey.isGlobal
                            ? "The shortcut mutes the microphone from any app, even while Hermes Voice is in the background. Other apps won't receive the key."
                            : "The shortcut works while Hermes Voice is the active app."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .onAppear { devices.refresh() }
        }
    }

    /// Click-to-record shortcut field: click, press the new combo, done.
    /// Esc cancels. Combos need ⌘, ⌃, or ⌥; function keys may stand alone.
    struct HotkeyRecorder: View {
        @Binding var combo: HotkeyCombo
        @State private var recording = false
        @State private var monitor: Any?

        var body: some View {
            HStack {
                Button {
                    recording ? stopRecording() : startRecording()
                } label: {
                    Text(recording ? "Press keys…" : combo.displayString)
                        .frame(minWidth: 110)
                }
                .help("Click, then press the new shortcut. Esc cancels.")
                if combo != .default {
                    Button("Reset") { combo = .default }
                        .disabled(recording)
                }
            }
            .onDisappear { stopRecording() }
        }

        private func startRecording() {
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == UInt16(kVK_Escape) {
                    stopRecording()
                    return nil
                }
                guard let recorded = HotkeyCombo(recording: event) else {
                    NSSound.beep()
                    return nil
                }
                combo = recorded
                stopRecording()
                return nil
            }
        }

        private func stopRecording() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
#endif
