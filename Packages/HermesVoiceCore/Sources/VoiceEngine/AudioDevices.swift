import AVFoundation
import Foundation
import Observation

#if os(macOS)
    import CoreAudio
#endif

/// A selectable audio endpoint, identified by its stable system UID.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Persisted device choices, readable synchronously from the audio engine
/// start paths (no actor hop). `nil` means "system default".
public enum AudioDevicePreference {
    static let inputKey = "audioSelectedInputUID"
    static let outputKey = "audioSelectedOutputUID"

    public static var inputUID: String? {
        get { UserDefaults.standard.string(forKey: inputKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: inputKey) }
            else { UserDefaults.standard.removeObject(forKey: inputKey) }
        }
    }

    public static var outputUID: String? {
        get { UserDefaults.standard.string(forKey: outputKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: outputKey) }
            else { UserDefaults.standard.removeObject(forKey: outputKey) }
        }
    }
}

/// Observable device list + selection for the pickers. Selection writes
/// through to `AudioDevicePreference` and pokes the live capture engine so a
/// change takes effect mid-conversation (output changes apply on the next
/// spoken reply — players bind their device when playback starts).
///
/// On iOS `outputs` stays empty: apps can't choose an output route directly;
/// the UI offers the system route picker instead.
@MainActor
@Observable
public final class AudioDeviceCatalog {
    public static let shared = AudioDeviceCatalog()

    public private(set) var inputs: [AudioDeviceInfo] = []
    public private(set) var outputs: [AudioDeviceInfo] = []

    public var selectedInputUID: String? = AudioDevicePreference.inputUID {
        didSet {
            guard oldValue != selectedInputUID else { return }
            AudioDevicePreference.inputUID = selectedInputUID
            applyInputSelection()
        }
    }

    public var selectedOutputUID: String? = AudioDevicePreference.outputUID {
        didSet {
            guard oldValue != selectedOutputUID else { return }
            AudioDevicePreference.outputUID = selectedOutputUID
        }
    }

    private init() {
        refresh()
        startObservingDeviceChanges()
    }

    /// Rebuild the device lists from the system.
    public func refresh() {
        #if os(macOS)
            inputs = MacAudioDevices.devices(scope: kAudioObjectPropertyScopeInput)
            outputs = MacAudioDevices.devices(scope: kAudioObjectPropertyScopeOutput)
        #else
            let session = AVAudioSession.sharedInstance()
            inputs = (session.availableInputs ?? []).map {
                AudioDeviceInfo(uid: $0.uid, name: $0.portName)
            }
            outputs = []
        #endif
    }

    /// Picker rows for an input selector: live devices plus, when the saved
    /// choice has vanished (headset unplugged), a placeholder row so the
    /// picker still shows what's selected instead of an unmatched tag.
    public var inputChoices: [AudioDeviceInfo] {
        choices(in: inputs, selected: selectedInputUID)
    }

    public var outputChoices: [AudioDeviceInfo] {
        choices(in: outputs, selected: selectedOutputUID)
    }

    private func choices(in devices: [AudioDeviceInfo], selected: String?) -> [AudioDeviceInfo] {
        guard let selected, !devices.contains(where: { $0.uid == selected }) else {
            return devices
        }
        return devices + [AudioDeviceInfo(uid: selected, name: "Unavailable device")]
    }

    private func applyInputSelection() {
        #if os(iOS)
            // `setPreferredInput` applies asynchronously; restarting the
            // engine here would rebuild it on the old route. The capture
            // service watches for the resulting route change and rebuilds a
            // running engine once the input has actually moved.
            let session = AVAudioSession.sharedInstance()
            if let uid = selectedInputUID,
                let port = session.availableInputs?.first(where: { $0.uid == uid })
            {
                try? session.setPreferredInput(port)
            } else {
                try? session.setPreferredInput(nil)
            }
        #else
            // Rebuild a running capture engine on the newly selected device;
            // a no-op when no conversation is active.
            AudioCaptureService.shared.reconfigure()
        #endif
    }

    private func startObservingDeviceChanges() {
        #if os(macOS)
            MacAudioDevices.onDeviceListChange { [weak self] in
                self?.refresh()
            }
        #else
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        #endif
    }
}

#if os(macOS)
    /// CoreAudio HAL helpers: enumerate devices per direction, translate the
    /// persisted UID back to a live `AudioDeviceID`, and pin an
    /// `AVAudioEngine` IO unit to a device. All best-effort — any failure
    /// leaves the system default in place.
    enum MacAudioDevices {
        static func devices(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
            allDeviceIDs().compactMap { id in
                guard channelCount(id, scope: scope) > 0,
                    let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                    let name = stringProperty(id, selector: kAudioObjectPropertyName)
                else { return nil }
                return AudioDeviceInfo(uid: uid, name: name)
            }
        }

        static func resolve(uid: String) -> AudioDeviceID? {
            allDeviceIDs().first {
                stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
            }
        }

        /// Pin an engine IO audio unit (input or output node) to a device.
        @discardableResult
        static func setDevice(_ deviceID: AudioDeviceID, on unit: AudioUnit) -> Bool {
            var id = deviceID
            return AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        }

        /// Apply the persisted input selection to a capture engine, before
        /// the tap is installed and the engine starts.
        static func applyPreferredInput(to engine: AVAudioEngine) {
            guard let uid = AudioDevicePreference.inputUID,
                let deviceID = resolve(uid: uid),
                let unit = engine.inputNode.audioUnit
            else { return }
            setDevice(deviceID, on: unit)
        }

        /// Apply the persisted output selection to a playback engine, before
        /// it starts.
        static func applyPreferredOutput(to engine: AVAudioEngine) {
            guard let uid = AudioDevicePreference.outputUID,
                let deviceID = resolve(uid: uid),
                let unit = engine.outputNode.audioUnit
            else { return }
            setDevice(deviceID, on: unit)
        }

        static func onDeviceListChange(_ handler: @escaping @MainActor () -> Void) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main
            ) { _, _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
        }

        // MARK: HAL plumbing

        private static func allDeviceIDs() -> [AudioDeviceID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard
                AudioObjectGetPropertyDataSize(
                    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
                size > 0
            else { return [] }
            var ids = [AudioDeviceID](
                repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
                    == noErr
            else { return [] }
            return ids
        }

        private static func channelCount(
            _ id: AudioDeviceID, scope: AudioObjectPropertyScope
        ) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
                size > 0
            else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
                return 0
            }
            let list = UnsafeMutableAudioBufferListPointer(
                raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }

        private static func stringProperty(
            _ id: AudioDeviceID, selector: AudioObjectPropertySelector
        ) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<CFString?>.size)
            var value: CFString?
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
            }
            guard status == noErr, let value else { return nil }
            return value as String
        }
    }
#endif
