import AVFoundation
import CoreAudio
import Observation
import OSLog

/// Lightweight wrapper over the Core Audio HAL for *input* device
/// discovery and selection.
///
/// On macOS, `AVAudioEngine.inputNode` defaults to the system input
/// device. To force a specific microphone we have to set the audio
/// unit's `kAudioOutputUnitProperty_CurrentDevice` *before* starting
/// the engine — there is no equivalent in `AVAudioSession` (which is
/// barely a thing on macOS).
///
/// The class also subscribes to default-device changes and posts a
/// notification, so the UI footer can refresh its label when the user
/// flips devices in System Settings.
@MainActor
@Observable
final class AudioDeviceManager {
    @ObservationIgnored nonisolated static let log = Logger(subsystem: "app.notype", category: "audio.devices")
    @ObservationIgnored private static let selectedUIDKey = "notype.selectedInputDeviceUID"

    @ObservationIgnored static let shared = AudioDeviceManager()

    struct Device: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// All available *input* devices, populated on init and refreshed
    /// when `kAudioHardwarePropertyDevices` changes.
    private(set) var inputs: [Device] = []
    /// The system's default input device — what we fall back to when
    /// the user picks "System default" or hasn't picked anything.
    private(set) var systemDefault: Device?

    /// User-pinned device UID. `nil` means "follow system default".
    /// Persisted to `UserDefaults` so the choice survives relaunches.
    var selectedUID: String? {
        didSet {
            UserDefaults.standard.set(selectedUID, forKey: Self.selectedUIDKey)
        }
    }

    @ObservationIgnored private var listenerInstalled = false

    init() {
        self.selectedUID = UserDefaults.standard.string(forKey: Self.selectedUIDKey)
        refresh()
        installDeviceListChangeListener()
    }

    /// The device the recorder should actually open. Returns the pinned
    /// device if it's still present, otherwise the system default,
    /// otherwise nil (which means "let the engine pick").
    var effectiveDevice: Device? {
        if let uid = selectedUID, let pinned = inputs.first(where: { $0.uid == uid }) {
            return pinned
        }
        return systemDefault
    }

    /// Human-readable label for the picker footer.
    var effectiveLabel: String {
        if let uid = selectedUID, let pinned = inputs.first(where: { $0.uid == uid }) {
            return pinned.name
        }
        if let def = systemDefault {
            return "\(def.name) (System)"
        }
        return "Default Input"
    }

    func refresh() {
        inputs = Self.fetchInputs()
        systemDefault = Self.fetchSystemDefault().flatMap { id in
            inputs.first(where: { $0.id == id })
        }
    }

    // MARK: - HAL property listeners

    private func installDeviceListChangeListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            listenerInstalled = true
        } else {
            Self.log.error("failed to register HAL listener: \(status)")
        }
    }

    // MARK: - Static HAL helpers

    private static func fetchInputs() -> [Device] {
        var size: UInt32 = 0
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id -> Device? in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal),
                  let name = deviceName(id)
            else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    private static func fetchSystemDefault() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// Prefer the human-friendly `kAudioObjectPropertyName`; fall back
    /// to the unique-name selector if name isn't readable for some
    /// reason (e.g. virtual aggregates).
    private static func deviceName(_ id: AudioDeviceID) -> String? {
        if let n = stringProperty(id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal), !n.isEmpty {
            return n
        }
        return stringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size: UInt32 = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    // MARK: - Apply to engine

    /// Force `engine.inputNode` to read from `device`. Must be called
    /// before `engine.start()`. Returns `true` if the HAL accepted the
    /// override; `false` falls back to the system default.
    @discardableResult
    nonisolated static func apply(_ device: Device, to engine: AVAudioEngine) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            log.error("AudioUnitSetProperty(CurrentDevice) failed: \(status) for \(device.name, privacy: .public)")
            return false
        }
        return true
    }
}
