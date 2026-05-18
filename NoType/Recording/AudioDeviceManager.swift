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
    // Static UserDefaults keys are plain strings — nonisolated so the
    // nonisolated `loadPreferBuiltInOverBluetooth(from:)` helper can
    // reference them without hopping to MainActor.
    @ObservationIgnored nonisolated private static let selectedUIDKey = "notype.selectedInputDeviceUID"
    @ObservationIgnored nonisolated private static let preferBuiltInOverBluetoothKey = "notype.preferBuiltInOverBluetooth"

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
        self.preferBuiltInOverBluetooth = Self.loadPreferBuiltInOverBluetooth(from: .standard)
        refresh()
        installDeviceListChangeListener()
    }

    /// Pure: resolve the persisted BT-avoidance preference, defaulting
    /// to ON when the key is absent. Uses the `object(forKey:) as? Bool`
    /// idiom rather than `bool(forKey:)` so absent keys land on the
    /// documented ON default — silently regressing to `bool(forKey:)`
    /// would flip every existing user to OFF. Pinned by
    /// `AudioDeviceManagerTests` so a future refactor can't bypass the
    /// idiom without a test failure.
    nonisolated static func loadPreferBuiltInOverBluetooth(from defaults: UserDefaults) -> Bool {
        let stored = defaults.object(forKey: preferBuiltInOverBluetoothKey) as? Bool
        return stored ?? true
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

    /// Human-readable label for the picker footer. Delegates to the
    /// pure static helper so the label policy stays in lockstep with
    /// `pickEffectiveDevice` — both honour pin first, then BT
    /// avoidance, then system default.
    var effectiveLabel: String {
        Self.formatEffectiveLabel(
            inputs: inputs,
            selectedUID: selectedUID,
            systemDefault: systemDefault,
            preferBuiltInOverBluetooth: preferBuiltInOverBluetooth
        )
    }

    /// Pure: render the picker footer label for the current state.
    /// Mirror of `pickEffectiveDevice`'s decision so the label stays
    /// honest — the user always sees what NoType will actually record
    /// from. Surfacing the BT-avoidance fallback explicitly
    /// (`"(avoiding <BT name>)"`) tells the user why the label
    /// doesn't match System Settings' default. `"(System)"` is the
    /// marker for the straight-pass-through case.
    nonisolated static func formatEffectiveLabel(
        inputs: [Device],
        selectedUID: String?,
        systemDefault: Device?,
        preferBuiltInOverBluetooth: Bool
    ) -> String {
        if let uid = selectedUID, let pinned = inputs.first(where: { $0.uid == uid }) {
            return pinned.name
        }
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

    /// Install listeners for two HAL properties on the system audio
    /// object:
    ///
    ///   - `kAudioHardwarePropertyDevices` — fires when devices are
    ///     plugged / unplugged / connected / disconnected. Keeps
    ///     `inputs` fresh.
    ///   - `kAudioHardwarePropertyDefaultInputDevice` — fires when the
    ///     user flips the default input in System Settings → Sound,
    ///     even though no device was added or removed. Without this,
    ///     `systemDefault` would stay stale until the next app launch
    ///     and the BT-avoidance fallback would silently fire (or fail
    ///     to fire) against the wrong premise.
    ///
    /// Both listeners share the same refresh block — both `inputs` and
    /// `systemDefault` are derived from the same HAL state, so it's
    /// cheaper to refresh everything than to maintain two narrower
    /// refresh paths. Listener blocks are dispatched on
    /// `DispatchQueue.main`, which runs on the main thread / main
    /// actor — `MainActor.assumeIsolated` is the synchronous,
    /// no-extra-hop variant; the original `Task { @MainActor in … }`
    /// added a second scheduling hop that opened a race where a fast
    /// "pull AirPods → press hotkey" sequence could observe a stale
    /// `effectiveDevice`.
    private func installDeviceListChangeListener() {
        guard !listenerInstalled else { return }

        let refresh: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        var deviceListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceListStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceListAddress,
            DispatchQueue.main,
            refresh
        )

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultInputStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            refresh
        )

        if deviceListStatus == noErr && defaultInputStatus == noErr {
            listenerInstalled = true
        } else {
            Self.log.error("failed to register HAL listeners: devices=\(deviceListStatus) defaultInput=\(defaultInputStatus)")
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

    // MARK: - Apply to AVAudioEngine (onboarding MicProbe only)

    /// Force `engine.inputNode` to read from `device`. Must be called
    /// before `engine.start()`. Returns `true` if the HAL accepted the
    /// override; `false` falls back to the system default.
    ///
    /// **Used exclusively by `NoType/Onboarding/MicProbe.swift`** for
    /// the onboarding mic-check spectrum meter — that path stays on
    /// `AVAudioEngine` because the BT-glitch concern that motivated
    /// `AudioRecorder`'s HAL rewrite doesn't apply during onboarding
    /// (users aren't holding the hotkey while listening to music in
    /// the first-launch wizard). The real recording path
    /// (`AudioRecorder`) opens the device via
    /// `AudioDeviceCreateIOProcIDWithBlock` and doesn't touch this
    /// method.
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

    // MARK: - HAL stream format

    /// Read the device's *input* stream format directly from Core
    /// Audio. Returns `nil` when the HAL refuses (aggregate devices in
    /// odd states, devices that vanish mid-call, etc.).
    ///
    /// `AudioRecorder`'s HAL path uses this to size the
    /// `AVAudioConverter` (input fmt → 16 kHz mono float32) before
    /// opening the IOProc. Pure / synchronous / hot-path-safe — no
    /// MainActor hop, no allocations beyond the inout ASBD.
    nonisolated static func inputStreamFormat(for deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            return nil
        }
        return asbd
    }

    /// Pure: turn an `AudioStreamBasicDescription` into the matching
    /// `AVAudioFormat`. Returned object is what the HAL IOProc adapter
    /// hands to `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` so the
    /// buffer view aligns 1:1 with the bytes the HAL just delivered.
    /// `AVAudioFormat(streamDescription:)` is a thin Cocoa wrapper —
    /// it doesn't allocate output buffers, just records the metadata.
    nonisolated static func avAudioFormat(from asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        var asbd = asbd
        return AVAudioFormat(streamDescription: &asbd)
    }
}
