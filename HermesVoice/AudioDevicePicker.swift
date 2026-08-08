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

    /// The audio sheet opened from the conversation header.
    struct AudioDevicesSheet: View {
        var devices = AudioDeviceCatalog.shared
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
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
                }
                .navigationTitle("Audio")
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
