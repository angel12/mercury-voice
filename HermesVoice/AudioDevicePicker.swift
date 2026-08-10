import SwiftUI
import VoiceEngine

#if os(iOS)
    import AVKit
#endif

/// Microphone selector shared by the macOS Settings pane and the iOS audio
/// sheet. `nil` = system default; a vanished device shows as "Unavailable
/// device" via `inputChoices` so the picker never has an unmatched tag.
struct AudioInputPicker: View {
    @Bindable var devices: AudioDeviceCatalog

    var body: some View {
        Picker("Microphone", selection: $devices.selectedInputUID) {
            Text("System Default").tag(String?.none)
            ForEach(devices.inputChoices) { device in
                Text(device.name).tag(String?.some(device.uid))
            }
        }
    }
}

#if os(macOS)
    /// Speaker selector — macOS only; iOS output routing belongs to the
    /// system route picker.
    struct AudioOutputPicker: View {
        @Bindable var devices: AudioDeviceCatalog

        var body: some View {
            Picker("Output", selection: $devices.selectedOutputUID) {
                Text("System Default").tag(String?.none)
                ForEach(devices.outputChoices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
        }
    }
#endif

#if os(iOS)
    /// The system output route picker (AirPlay / Bluetooth / speaker) — iOS
    /// offers no API to set an output device directly.
    struct AudioRoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.prioritizesVideoDevices = false
            return view
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }

    /// The settings sheet opened from the conversation header: audio
    /// devices, sounds, and appearance.
    struct AudioDevicesSheet: View {
        var devices = AudioDeviceCatalog.shared
        @Environment(\.dismiss) private var dismiss
        @AppStorage(CuePreference.key) private var cuesEnabled = true
        @AppStorage(ThemePreference.key) private var theme = ThemePreference.system

        var body: some View {
            NavigationStack {
                Form {
                    Section("Appearance") {
                        Picker("Theme", selection: $theme) {
                            ForEach(ThemePreference.allCases) { choice in
                                Text(choice.label).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Microphone") {
                        AudioInputPicker(devices: devices)
                            .pickerStyle(.inline)
                            .labelsHidden()
                    }
                    Section("Output") {
                        HStack {
                            Text("Speaker or headphones")
                            Spacer()
                            AudioRoutePicker()
                                .frame(width: 44, height: 44)
                        }
                        Text("Output is chosen with the system route picker.")
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
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear { devices.refresh() }
        }
    }
#endif
