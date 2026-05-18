import XCTest
import CoreAudio
@testable import NoType

/// Pins `AudioDeviceManager.pickEffectiveDevice` — the pure function
/// that decides which input the recorder should open from the current
/// HAL inventory + user preference.
///
/// The function exists so we can drive every relevant case (no pin,
/// pin present, pin missing, BT default + built-in available, BT
/// default + no built-in, etc.) against synthetic `Device` fixtures.
/// Live HAL hardware can't simulate "Bluetooth headset connected" on
/// CI, and an integration test that depends on plugging in real
/// headphones isn't a real test.
///
/// The BT-avoidance fallback exists because asking `AVAudioEngine`
/// for input from a BT headset forces macOS to switch the device
/// from A2DP (output-only, hi-fi) to HFP/SCO (telephony codec) —
/// which breaks audio ducking and downgrades any music the user is
/// listening to. See `NoType/Recording/CLAUDE.md` "Bluetooth input
/// avoidance".
final class AudioDeviceManagerTests: XCTestCase {

    // MARK: - Synthetic device fixtures

    private func makeDevice(uid: String, name: String, transport: UInt32) -> AudioDeviceManager.Device {
        AudioDeviceManager.Device(
            id: AudioDeviceID(uid.hashValue & 0xffffffff),
            uid: uid,
            name: name,
            transportType: transport
        )
    }

    private var builtIn: AudioDeviceManager.Device {
        makeDevice(uid: "BuiltInMic", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)
    }

    private var btHeadset: AudioDeviceManager.Device {
        makeDevice(uid: "AirPodsPro", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
    }

    private var bleHeadset: AudioDeviceManager.Device {
        makeDevice(uid: "BLEDevice", name: "Some LE Audio Headset", transport: kAudioDeviceTransportTypeBluetoothLE)
    }

    private var usbMic: AudioDeviceManager.Device {
        makeDevice(uid: "USBMic", name: "Shure MV7", transport: kAudioDeviceTransportTypeUSB)
    }

    // MARK: - Pinned device wins

    func test_pin_present_overridesBuiltInFallback_evenIfBT() {
        // User explicitly pinned BT — respect the choice. The BT
        // avoidance fallback exists for users who haven't expressed
        // an opinion; an explicit pin is an opinion.
        let inputs = [builtIn, btHeadset]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: btHeadset.uid,
            systemDefault: builtIn,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, btHeadset)
    }

    func test_pin_missing_fallsThroughToSystemDefault() {
        // Pinned UID no longer in `inputs` (device unplugged) →
        // ignore the pin and fall through.
        let inputs = [builtIn]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: "GoneDevice",
            systemDefault: builtIn,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, builtIn)
    }

    // MARK: - BT avoidance ON

    func test_btAvoidance_on_systemBT_builtinPresent_picksBuiltin() {
        // The headline case. User has BT headphones as system default
        // input; we transparently grab the built-in mic to keep the
        // headphones in A2DP for music playback.
        let inputs = [builtIn, btHeadset]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: btHeadset,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, builtIn)
    }

    func test_btAvoidance_on_systemBLE_builtinPresent_picksBuiltin() {
        // BLE Audio (LC3 stack) still forces the profile switch when
        // the mic stream opens, so we avoid it the same way.
        let inputs = [builtIn, bleHeadset]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: bleHeadset,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, builtIn)
    }

    func test_btAvoidance_on_systemBT_noBuiltin_keepsBT() {
        // Mac without a built-in mic (e.g. headless Mac mini setup) —
        // no fallback target, so don't second-guess the user.
        let inputs = [btHeadset, usbMic]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: btHeadset,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, btHeadset)
    }

    func test_btAvoidance_on_systemUSB_unchanged() {
        // Non-BT system default — no fallback applies regardless of
        // the toggle. USB mics don't have the A2DP/HFP problem.
        let inputs = [builtIn, usbMic]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: usbMic,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, usbMic)
    }

    func test_btAvoidance_on_systemBuiltin_unchanged() {
        // System default already the built-in mic — no-op.
        let inputs = [builtIn]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: builtIn,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, builtIn)
    }

    // MARK: - BT avoidance OFF

    func test_btAvoidance_off_systemBT_keepsBT() {
        // User opted out (e.g. genuinely wants BT mic). Honour the
        // system default — no override.
        let inputs = [builtIn, btHeadset]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: btHeadset,
            preferBuiltInOverBluetooth: false
        )
        XCTAssertEqual(pick, btHeadset)
    }

    // MARK: - Degenerate inputs

    func test_emptyInputs_returnsNil() {
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: [],
            selectedUID: nil,
            systemDefault: nil,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertNil(pick)
    }

    func test_noSystemDefault_pinHonoured() {
        let inputs = [usbMic]
        let pick = AudioDeviceManager.pickEffectiveDevice(
            inputs: inputs,
            selectedUID: usbMic.uid,
            systemDefault: nil,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(pick, usbMic)
    }

    // MARK: - Device.isBluetooth / isBuiltIn

    func test_device_isBluetooth_classic() {
        XCTAssertTrue(btHeadset.isBluetooth)
        XCTAssertFalse(btHeadset.isBuiltIn)
    }

    func test_device_isBluetooth_le() {
        XCTAssertTrue(bleHeadset.isBluetooth)
        XCTAssertFalse(bleHeadset.isBuiltIn)
    }

    func test_device_isBuiltIn() {
        XCTAssertTrue(builtIn.isBuiltIn)
        XCTAssertFalse(builtIn.isBluetooth)
    }

    func test_device_isNeither_forUSB() {
        XCTAssertFalse(usbMic.isBluetooth)
        XCTAssertFalse(usbMic.isBuiltIn)
    }

    func test_device_isNeither_forUnknownTransport() {
        // Aggregate devices and broken kexts return 0
        // (`kAudioDeviceTransportTypeUnknown`) — must NOT match either
        // helper or the fallback would misfire.
        let unknown = makeDevice(uid: "?", name: "Unknown", transport: 0)
        XCTAssertFalse(unknown.isBluetooth)
        XCTAssertFalse(unknown.isBuiltIn)
    }

    // MARK: - effectiveLabel (mirror of pickEffectiveDevice)

    func test_effectiveLabel_pinned_returnsPlainDeviceName() {
        // Explicit pin: label is just the device name, no marker. The
        // user picked this on purpose — no "(System)" / "(avoiding…)"
        // chrome.
        let inputs = [builtIn, usbMic]
        let label = AudioDeviceManager.formatEffectiveLabel(
            inputs: inputs,
            selectedUID: usbMic.uid,
            systemDefault: builtIn,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(label, "Shure MV7")
    }

    func test_effectiveLabel_btAvoidanceEngaged_showsAvoidingMarker() {
        // The headline label — surfaces the fallback to the user so
        // they see why NoType isn't recording from their stated System
        // Settings default. Format pinned: `"<builtin> (avoiding <bt>)"`.
        let inputs = [builtIn, btHeadset]
        let label = AudioDeviceManager.formatEffectiveLabel(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: btHeadset,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(label, "MacBook Pro Microphone (avoiding AirPods Pro)")
    }

    func test_effectiveLabel_systemDefaultPassThrough_showsSystemMarker() {
        // No pin, no BT-avoidance engaged — show the system default
        // with "(System)" so the user knows they're following System
        // Settings.
        let inputs = [builtIn, usbMic]
        let label = AudioDeviceManager.formatEffectiveLabel(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: usbMic,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(label, "Shure MV7 (System)")
    }

    func test_effectiveLabel_btAvoidanceOff_systemBT_showsSystemMarker() {
        // User opted out of BT avoidance — the label honestly reflects
        // that NoType will record from the BT mic.
        let inputs = [builtIn, btHeadset]
        let label = AudioDeviceManager.formatEffectiveLabel(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: btHeadset,
            preferBuiltInOverBluetooth: false
        )
        XCTAssertEqual(label, "AirPods Pro (System)")
    }

    func test_effectiveLabel_btAvoidanceOn_noBuiltIn_fallsThroughToSystem() {
        // Mac mini / Mac Studio with no built-in mic: even with BT
        // avoidance on, we can't fall back, so we honestly say
        // "(System)" rather than lying about an "(avoiding…)" state.
        let inputs = [btHeadset, usbMic]
        let label = AudioDeviceManager.formatEffectiveLabel(
            inputs: inputs,
            selectedUID: nil,
            systemDefault: btHeadset,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(label, "AirPods Pro (System)")
    }

    func test_effectiveLabel_emptyInputs_returnsDefaultInput() {
        // Degenerate state: HAL hasn't reported any devices yet (or
        // they all lost input streams) → "Default Input" is a stable
        // placeholder that survives until the next refresh.
        let label = AudioDeviceManager.formatEffectiveLabel(
            inputs: [],
            selectedUID: nil,
            systemDefault: nil,
            preferBuiltInOverBluetooth: true
        )
        XCTAssertEqual(label, "Default Input")
    }

    // MARK: - loadPreferBuiltInOverBluetooth (UserDefaults default-ON idiom)

    private func makeIsolatedDefaults(suite: String = #function) -> UserDefaults {
        // Per-test suite name so writes don't leak between tests or
        // pollute `UserDefaults.standard`. `removePersistentDomain` is
        // both setup and teardown — no test leaks if the harness
        // process is restarted between runs.
        let name = "test.audioDeviceManager.\(suite)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func test_loadPreference_absentKey_defaultsToOn() {
        // The headline guarantee. A future regression from
        // `object(forKey:) as? Bool` to `bool(forKey:)` would silently
        // flip every existing user — pin the idiom in a test.
        let defaults = makeIsolatedDefaults()
        XCTAssertTrue(AudioDeviceManager.loadPreferBuiltInOverBluetooth(from: defaults))
    }

    func test_loadPreference_storedTrue_isOn() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "notype.preferBuiltInOverBluetooth")
        XCTAssertTrue(AudioDeviceManager.loadPreferBuiltInOverBluetooth(from: defaults))
    }

    func test_loadPreference_storedFalse_isOff() {
        // User explicitly opted out — must round-trip.
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "notype.preferBuiltInOverBluetooth")
        XCTAssertFalse(AudioDeviceManager.loadPreferBuiltInOverBluetooth(from: defaults))
    }

    func test_loadPreference_corruptStringValue_defaultsToOn() {
        // Defensive: if something writes a non-Bool to the key (third-
        // party defaults editor, manual `defaults write`), the `as?`
        // cast fails and we fall back to ON rather than crashing or
        // returning a misleading false.
        let defaults = makeIsolatedDefaults()
        defaults.set("not-a-bool", forKey: "notype.preferBuiltInOverBluetooth")
        XCTAssertTrue(AudioDeviceManager.loadPreferBuiltInOverBluetooth(from: defaults))
    }

    // MARK: - HAL stream-format helpers (consumed by AudioRecorder's HAL path)

    /// Build a synthetic interleaved-float32 ASBD at an arbitrary
    /// sample rate / channel count for round-trip testing.
    /// `AVAudioFormat(streamDescription:)` accepts the standard
    /// representations Core Audio hands us for built-in / USB / BT
    /// devices on macOS — float32, non-interleaved is the universal
    /// shape today; 16-bit-int devices still exist in the wild but
    /// `AVAudioConverter` handles both.
    private func makeFloat32ASBD(
        sampleRate: Double,
        channels: UInt32,
        interleaved: Bool
    ) -> AudioStreamBasicDescription {
        let bytesPerSample: UInt32 = 4
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved {
            flags |= kAudioFormatFlagIsNonInterleaved
        }
        let framesPerPacket: UInt32 = 1
        let bytesPerFrame = interleaved ? bytesPerSample * channels : bytesPerSample
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame * framesPerPacket,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
    }

    func test_avAudioFormat_roundsTripStandardBuiltInMic_44100Mono() {
        // Most MacBook built-in mics report 44.1 kHz mono float32.
        let asbd = makeFloat32ASBD(sampleRate: 44_100, channels: 1, interleaved: false)
        let fmt = AudioDeviceManager.avAudioFormat(from: asbd)
        XCTAssertNotNil(fmt)
        XCTAssertEqual(fmt?.sampleRate, 44_100)
        XCTAssertEqual(fmt?.channelCount, 1)
        XCTAssertEqual(fmt?.commonFormat, .pcmFormatFloat32)
    }

    func test_avAudioFormat_roundsTripUSBMic_48000Mono() {
        // Many USB mics ship 48 kHz native.
        let asbd = makeFloat32ASBD(sampleRate: 48_000, channels: 1, interleaved: false)
        let fmt = AudioDeviceManager.avAudioFormat(from: asbd)
        XCTAssertEqual(fmt?.sampleRate, 48_000)
        XCTAssertEqual(fmt?.channelCount, 1)
    }

    func test_avAudioFormat_roundsTripStereoDevice() {
        // Aggregate / stereo USB interfaces — AVAudioConverter will
        // downmix to mono in our 16 kHz mono output, but the HAL
        // adapter must preserve the source's channel count so the
        // bufferListNoCopy alignment matches the actual bytes.
        let asbd = makeFloat32ASBD(sampleRate: 48_000, channels: 2, interleaved: false)
        let fmt = AudioDeviceManager.avAudioFormat(from: asbd)
        XCTAssertEqual(fmt?.channelCount, 2)
    }
}
