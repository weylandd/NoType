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
    @ObservationIgnored fileprivate static let preferBuiltInOverBluetoothKey = "notype.preferBuiltInOverBluetooth"

    @ObservationIgnored static let shared = AudioDeviceManager()

    struct Device: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        /// Core Audio transport type — `kAudioDeviceTransportType*`
        /// constants. Powers `isBluetooth` / `isBuiltIn` so we can
        /// auto-prefer the laptop mic over a connected BT headset
        /// (whose mic forces the OS into HFP/SCO and downgrades
        /// music output from A2DP to telephony quality).
        let transportType: UInt32

        /// True for both Classic BR/EDR (`Bluetooth`) and BLE Audio
        /// (`BluetoothLE`) — both transports forcibly switch to a
        /// telephony codec the moment a mic stream is opened.
        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var isBuiltIn: Bool {
            transportType == kAudioDeviceTransportTypeBuiltIn
        }
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

    /// When ON and the user hasn't explicitly pinned a device,
    /// `effectiveDevice` falls back to the built-in mic instead of
    /// the system default if that default is a Bluetooth headset.
    /// Default ON — fixes the surprise where pressing the hotkey
    /// while listening to music on BT headphones downgrades the
    /// headphones from A2DP (high-fi, output-only) to HFP/SCO
    /// (telephony, with mic) and breaks ducking. Users who actually
    /// want the BT mic can either flip this off here or pin the BT
    /// device explicitly in the picker (pinning always wins over
    /// the fallback). Persisted to `UserDefaults`.
    var preferBuiltInOverBluetooth: Bool {
        didSet {
            UserDefaults.standard.set(
                preferBuiltInOverBluetooth,
                forKey: Self.preferBuiltInOverBluetoothKey
            )
        }
    }

    @ObservationIgnored private var listenerInstalled = false

    init() {
        self.selectedUID = UserDefaults.standard.string(forKey: Self.selectedUIDKey)
        // Read with `object(forKey:) as? Bool` so the absent-key case
        // resolves to the default ON, not the false default for
        // `bool(forKey:)`. Same idiom as `AppState.dictionaryEnabled`.
        let storedPref = UserDefaults.standard.object(forKey: Self.preferBuiltInOverBluetoothKey) as? Bool
        self.preferBuiltInOverBluetooth = storedPref ?? true
        refresh()
        installDeviceListChangeListener()
    }

    /// The device the recorder should actually open. Returns the pinned
    /// device if it's still present, otherwise — when
    /// `preferBuiltInOverBluetooth` is on and the system default is a
    /// BT headset — the built-in mic, otherwise the system default,
    /// otherwise nil (which means "let the engine pick"). Delegates
    /// to the pure static helper so the policy is unit-testable
    /// without standing up a real HAL.
    var effectiveDevice: Device? {
        Self.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: selectedUID,
            systemDefault: systemDefault,
            preferBuiltInOverBluetooth: preferBuiltInOverBluetooth
        )
    }

    /// Human-readable label for the picker footer.
    var effectiveLabel: String {
        if let uid = selectedUID, let pinned = inputs.first(where: { $0.uid == uid }) {
            return pinned.name
        }
        // Surface the BT-avoidance fallback explicitly so the user
        // understands why the label doesn't match their System
        // Settings default. "(System)" stays as the marker for the
        // straight-pass-through case.
        if preferBuiltInOverBluetooth,
           let def = systemDefault,
           def.isBluetooth,
           let builtIn = inputs.first(where: { $0.isBuiltIn }) {
            return "\(builtIn.name) (avoiding \(def.name))"
        }
        if let def = systemDefault {
            return "\(def.name) (System)"
        }
        return "Default Input"
    }

    /// Pure: pick the input the recorder should open. Extracted so
    /// `AudioDeviceManagerTests` can pin the BT-avoidance policy
    /// against synthetic device fixtures without needing real HAL
    /// hardware.
    ///
    /// Decision order:
    /// 1. Explicit pin wins — the user picked this device on purpose.
    /// 2. `preferBuiltInOverBluetooth` ON + system default is BT +
    ///    a built-in mic exists → fall back to the built-in mic.
    /// 3. System default.
    /// 4. Nil (let `AVAudioEngine` pick).
    nonisolated static func pickEffectiveDevice(
        inputs: [Device],
        selectedUID: String?,
        systemDefault: Device?,
        preferBuiltInOverBluetooth: Bool
    ) -> Device? {
        if let uid = selectedUID, let pinned = inputs.first(where: { $0.uid == uid }) {
            return pinned
        }
        if preferBuiltInOverBluetooth,
           let def = systemDefault,
           def.isBluetooth,
           let builtIn = inputs.first(where: { $0.isBuiltIn }) {
            return builtIn
        }
        return systemDefault
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
            return Device(
                id: id,
                uid: uid,
                name: name,
                transportType: transportType(id)
            )
        }
    }

    /// Read the Core Audio transport type for a device. Returns 0
    /// when the HAL refuses (aggregate devices, broken kexts) — that
    /// value is `kAudioDeviceTransportTypeUnknown`, and the
    /// `isBluetooth` / `isBuiltIn` helpers correctly treat unknown
    /// devices as neither (so the BT fallback simply doesn't fire
    /// for them).
    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        guard status == noErr else { return 0 }
        return transport
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
