import AppKit
import CoreAudio
import IOKit
import OSLog

/// Pauses or mutes outside audio for the duration of a recording
/// session so background music doesn't bleed into the mic when the
/// user is recording without headphones.
///
/// **Three modes:**
///  - `.none` — no-op. Music continues; mic picks up the speakers.
///  - `.mute` — toggles `kAudioDevicePropertyMute` on the system
///    default *output* device. macOS silences every running app's
///    output (the volume slider stays where it was). On stop we
///    restore the prior mute state, so a user who was already on
///    mute before recording stays on mute after.
///  - `.pause` — synthesises a `NX_KEYTYPE_PLAY` system-defined
///    media-key event (down + up) on start, and again on stop.
///    Toggle semantics: every media app that responds to system
///    play/pause (Apple Music, Spotify, Safari/YouTube tab, Chrome,
///    QuickTime, VLC, IINA, …) flips its playback state. Public API,
///    no entitlements / private-framework risk.
///
/// **Shape parallels `SleepAssertion`'s RAII intent** — `@MainActor`
/// `final class`, owned by `AppState`, RAII-deinit safety net for the
/// mute-restore path so a missed `release()` doesn't strand the user's
/// system on mute forever. Acquired in `AppState.handleHotkeyPress`
/// after `session.start()` succeeds; released in the three terminal
/// session-end paths (`finalizeRecording` success arm,
/// `finalizeRecording` error catch, `cancelRecording`). Same
/// "recoverable failures do NOT release" rule as `SleepAssertion`.
///
/// Construction and activation are intentionally split (vs.
/// `SleepAssertion`'s `init(reason:) throws` shape) because
/// `Mode.none` is a valid no-op state — a throwing init would force
/// the caller to skip construction entirely when the user has the
/// toggle off, which complicates the `AppState` ownership pattern
/// (the optional `activeMusicInterruption` reference has to mean
/// "we're holding an active mute" rather than "we have an object").
/// Keeping `init()` cheap and pushing the side-effect into
/// `activate(mode:)` lets the optional carry the real semantics.
///
/// **Restore targets a snapshotted device.** Activation captures the
/// `AudioDeviceID` of the default output at the moment we mute it and
/// the release path restores that *specific* device, even if the user
/// has since changed the system default output. Without this, the
/// original muted device would stay muted indefinitely. See the
/// `savedOutputDeviceID` doc-comment.
///
/// **Limitation: manual mute toggle during the session.** We snapshot
/// the mute state at activate-time. If the user manually toggles mute
/// via the menu bar / Control Centre during the session, our release
/// re-applies the snapshotted state, which can briefly contradict
/// their intent. Acceptable given short session windows; a more
/// sophisticated implementation would diff against the current state
/// at release-time but the cost-benefit doesn't justify the added
/// complexity.
@MainActor
final class MusicInterruption {

    enum Mode: String, CaseIterable, Sendable, Codable {
        case none
        case mute
        case pause

        /// UserDefaults storage key.
        static let userDefaultsKey: String = "notype.musicInterruption"

        /// Picker label rendered in Settings → Audio.
        var label: String {
            switch self {
            case .none:  return "None"
            case .mute:  return "Mute"
            case .pause: return "Pause"
            }
        }

        /// Settings row subtitle reflects what the current selection
        /// will do to the user's audio. Pure / static so SettingsTabView
        /// stays declarative.
        static func subtitle(for mode: Mode) -> String {
            switch mode {
            case .none:
                return "Keep other audio playing without interruption."
            case .mute:
                return "Mute system output while recording, then restore the previous mute state."
            case .pause:
                return "Send a play/pause key to Apple Music, Spotify, Safari, and other media apps when recording starts; press it again when recording ends."
            }
        }
    }

    nonisolated private static let log = Logger(subsystem: "app.notype", category: "music")

    /// Mode the controller is currently "holding" — `.none` when
    /// inactive. Reads as the user-visible mode of the in-flight
    /// session even if the user has since changed
    /// `AppState.musicInterruptionMode` to something else (the policy
    /// is frozen at session start, like every other configurable).
    nonisolated(unsafe) private(set) var activeMode: Mode = .none

    /// Snapshotted mute state of the system output before we engaged
    /// `.mute`. `nil` when we don't currently hold the assertion.
    /// `nonisolated(unsafe)` for the same `deinit` safety-net reason
    /// as `SleepAssertion.assertionID`.
    nonisolated(unsafe) private var savedMuteState: Bool? = nil

    /// `AudioDeviceID` of the output device we muted at activate-time.
    /// `nil` when we don't currently hold the assertion. The release
    /// path targets *this* device, not whatever the current system
    /// default is — if the user changes default output mid-session,
    /// the originally-muted device stays muted unless we restore it
    /// by its captured ID. Same `nonisolated(unsafe)` rationale as
    /// `savedMuteState`.
    nonisolated(unsafe) private var savedOutputDeviceID: AudioDeviceID? = nil

    init() {}

    /// Engage the interruption. No-op when `mode == .none` or when an
    /// activation is already in flight (defends against `handleHotkeyPress`
    /// arriving twice if the press-handler is ever re-entered).
    func activate(mode: Mode) {
        guard activeMode == .none else { return }
        guard mode != .none else { return }
        activeMode = mode
        switch mode {
        case .none:
            break
        case .mute:
            // Snapshot the device ID *before* mutating so the release
            // path targets the same device even if the user changes
            // default output mid-session. If we can't resolve a
            // device, abort the activation cleanly so we don't leave
            // a phantom `activeMode == .mute` with nothing to restore.
            guard let outputID = Self.defaultOutputDevice() else {
                Self.log.warning("music: activate(.mute) — no default output device")
                activeMode = .none
                return
            }
            // Apply the mute. If the HAL set call failed, fall back
            // to `.none` rather than booking a release for a mute we
            // never engaged.
            guard let previous = Self.applyMute(true, on: outputID) else {
                Self.log.warning("music: activate(.mute) — applyMute failed, activation aborted")
                activeMode = .none
                return
            }
            savedOutputDeviceID = outputID
            savedMuteState = previous
        case .pause:
            Self.postMediaKey(NX_KEYTYPE_PLAY)
        }
    }

    /// Restore whatever we changed. Idempotent — repeated calls after
    /// the first are no-ops. Safe to call from `deinit`.
    func release() {
        defer { activeMode = .none; savedMuteState = nil; savedOutputDeviceID = nil }
        switch activeMode {
        case .none:
            return
        case .mute:
            // Restore the pre-session mute state on the *same* device
            // we muted. Targeting the snapshotted device ID survives
            // a mid-session default-output change. Nil saved state
            // means we never managed to read the original — leave the
            // captured device unmuted so the user isn't trapped on
            // mute. Nil device ID means activation aborted partway
            // through; nothing to restore.
            if let deviceID = savedOutputDeviceID {
                _ = Self.applyMute(savedMuteState ?? false, on: deviceID)
            }
        case .pause:
            // Symmetric toggle: pressing play/pause again on each app
            // that toggled with the first event returns it to the
            // playing state it was in before we touched it. Apps that
            // weren't playing before our first press get started by
            // the second press, which is the documented edge case —
            // see the `.pause` doc-comment.
            Self.postMediaKey(NX_KEYTYPE_PLAY)
        }
    }

    deinit {
        // Safety net only — production code paths always call release()
        // explicitly. Catches programmer mistakes so the user's system
        // isn't trapped on mute after a thrown error somewhere in the
        // session-end pipeline.
        //
        // `.pause` symmetric-toggle recovery is dispatched async to
        // main to keep the NSEvent / CGEvent post off this nonisolated
        // deinit (CGEvent posting from arbitrary threads is unsafe).
        // The trade-off: a crash inside the async window still leaves
        // music paused, but the explicit `release()` is the normal
        // path — deinit only catches missed-release programmer error.
        if activeMode == .mute,
           let prev = savedMuteState,
           let deviceID = savedOutputDeviceID {
            _ = Self.applyMute(prev, on: deviceID)
        } else if activeMode == .pause {
            DispatchQueue.main.async { Self.postMediaKey(NX_KEYTYPE_PLAY) }
        }
    }

    // MARK: - CoreAudio output mute

    /// Apply `desired` as the `kAudioDevicePropertyMute` value of the
    /// given output device. Returns the *previous* mute state on
    /// success, or `nil` if the HAL Set call failed (no point in the
    /// caller booking a release for a mute we never engaged) or if
    /// the device doesn't expose the property at all (external
    /// interfaces sometimes don't — built-in speakers always do).
    ///
    /// Returning `nil` on Set failure (vs. surfacing the
    /// pre-read state) is load-bearing: `activate(.mute)` uses the
    /// `nil` signal to abort the activation rather than holding a
    /// phantom assertion that would later restore a state we never
    /// changed.
    @discardableResult
    nonisolated private static func applyMute(_ desired: Bool, on deviceID: AudioDeviceID) -> Bool? {
        let previous = readMute(deviceID)
        let value: UInt32 = desired ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = value
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &v
        )
        if status != noErr {
            Self.log.warning("music: AudioObjectSetPropertyData(Mute=\(desired, privacy: .public)) status=\(status, privacy: .public)")
            return nil
        }
        return previous
    }

    nonisolated private static func readMute(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = 0
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muteValue)
        guard status == noErr else { return nil }
        return muteValue == 1
    }

    nonisolated private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Media key event

    /// Synthesise a system-defined NX media key down + up event for
    /// the given keycode (we use `NX_KEYTYPE_PLAY` = 16, the
    /// universal play/pause toggle). Posted at `.cghidEventTap` so
    /// every app sees it — the same surface the F8 / Touch Bar
    /// play/pause button uses.
    ///
    /// The NX system-defined event encoding: `data1` packs the
    /// keycode in the upper 16 bits, the state flag (0xA = down,
    /// 0xB = up) in bits 8–15, and a repeat counter (0) in the
    /// lower 8 bits. `subtype = 8` is `NX_SUBTYPE_AUX_CONTROL_BUTTONS`
    /// — the bus that handles play/pause / next / previous on the
    /// system bus.
    nonisolated private static func postMediaKey(_ keycode: Int32) {
        postSystemDefined(keycode: keycode, state: 0xA)
        postSystemDefined(keycode: keycode, state: 0xB)
    }

    nonisolated private static func postSystemDefined(keycode: Int32, state: Int32) {
        let data1 = (Int(keycode) << 16) | (Int(state) << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        )
        guard let cgEvent = event?.cgEvent else {
            Self.log.warning("music: postSystemDefined — failed to build CGEvent")
            return
        }
        cgEvent.post(tap: .cghidEventTap)
    }
}

/// `NX_KEYTYPE_PLAY` is declared in `IOKit/hidsystem/ev_keymap.h`
/// (C header) as `#define NX_KEYTYPE_PLAY 16`. Swift doesn't import
/// the `#define`-only header reliably so we redeclare it here. The
/// constant has been stable across macOS releases since 10.7 — if
/// Apple ever renumbers it, the media-key bus would break system-
/// wide, not just for us.
private let NX_KEYTYPE_PLAY: Int32 = 16
