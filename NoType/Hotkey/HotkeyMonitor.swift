import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Global push-to-talk hotkey monitor.
///
/// Installs a `CGEventTap` on a dedicated thread+runloop and dispatches
/// press / release of the configured `HotkeyBinding` to the main actor.
/// The binding decides which detection path runs:
///   - **Modifier keys** (Option/Control/Shift/Command/Fn) — bit-mask on
///     `CGEventFlags.rawValue` from `flagsChanged` events. This is the
///     original v1 path, just parameterized on the modifier's bit.
///   - **Non-modifier keys** (letters, digits, F-row, Space, …) —
///     virtual-key match on `keyDown`/`keyUp` events.
///
/// Escape (`kVK_Escape = 53`) is always wired to `onEscape`, regardless
/// of the binding, because it's the cancellation hotkey for an in-flight
/// session. As a consequence `HotkeyBinding.isAllowedAsHotkey` rejects
/// Escape so the user can't accidentally pick it.
///
/// `@unchecked Sendable`: `binding` and the `on*` closures are immutable
/// after init. `previousFlags` and `nonModifierHeld` are touched only on
/// the tap thread. `tap`, `runLoopSource`, `runLoop`, `thread`, and
/// `isActive` are written from the main actor (`start()` / `stop()`);
/// the `runLoopReady` semaphore provides the happens-before edge between
/// the tap thread's setup writes (`self.runLoop = …`) and the main
/// actor's reads in `stop()`.
final class HotkeyMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "hotkey")

    /// IOKit per-device-side modifier bits in `CGEventFlags.rawValue`.
    /// Right Option = `NX_DEVICERALTKEYMASK` (0x40); left = 0x20.
    /// Kept on the type so unit tests can reach it without a `HotkeyMonitor`
    /// instance — `HotkeyBinding` is the public source of truth, but
    /// this constant is referenced from the pure `detectTransition`
    /// helper below.
    static let rightOptionBit: UInt64 = 0x40

    /// Hardware keycode for the Escape key. `kVK_Escape = 53`. Used as
    /// the in-flight session cancellation hotkey — pressing Esc while
    /// recording aborts the session without sending to Gemini.
    static let escapeKeyCode: Int64 = 53

    enum Transition: Equatable {
        case pressed
        case released
        case none
    }

    private let binding:   HotkeyBinding
    private let onPress:   @MainActor @Sendable () -> Void
    private let onRelease: @MainActor @Sendable () -> Void
    private let onEscape:  @MainActor @Sendable () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    /// Set inside the tap thread's closure once `CFRunLoopGetCurrent()`
    /// has resolved. `stop()` reads it from the main actor after the
    /// `runLoopReady` semaphore has fired, so the cross-thread handoff
    /// is ordered by the semaphore's happens-before.
    private var runLoop: CFRunLoop?
    /// One-shot — signalled by the tap thread after it has stored its
    /// `runLoop`, added the source, and enabled the tap. `start()`
    /// waits on it before returning so `stop()` always has a valid
    /// `runLoop` to schedule cleanup on.
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var previousFlags: UInt64 = 0
    /// For non-modifier bindings: track whether the bound key is
    /// currently held so we only emit one press/release pair even when
    /// macOS auto-repeats keyDown events.
    private var nonModifierHeld: Bool = false
    /// Flipped to `false` at the top of `stop()`. Press / release Tasks
    /// dispatched to `@MainActor` check it before invoking the callback
    /// so a callback queued just before `stop()` doesn't fire `onPress`
    /// against a being-torn-down monitor — important during rebind,
    /// where the next monitor is installed immediately after.
    private var isActive: Bool = true

    init(
        binding:   HotkeyBinding = .default,
        onPress:   @escaping @MainActor @Sendable () -> Void,
        onRelease: @escaping @MainActor @Sendable () -> Void,
        onEscape:  @escaping @MainActor @Sendable () -> Void
    ) {
        self.binding   = binding
        self.onPress   = onPress
        self.onRelease = onRelease
        self.onEscape  = onEscape
    }

    /// Try to install the tap. Returns `false` if Accessibility isn't granted yet.
    /// Safe to call again later — the caller (PermissionsViewModel) polls.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else {
            Self.log.warning("Accessibility not granted; hotkey not installed")
            return false
        }

        // We always listen to keyDown (for Escape + non-modifier bindings)
        // and keyUp (for non-modifier release). We listen to flagsChanged
        // unconditionally too — modifier bindings need it, and a future
        // rebind to a modifier doesn't require re-creating the tap.
        // `.listenOnly` means we never consume — every keystroke still
        // reaches the focused app.
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.log.error("CGEvent.tapCreate returned nil")
            return false
        }

        self.tap = newTap

        // Capture the semaphore directly so the early-exit defer below
        // can still signal it even if `[weak self]` resolves to nil
        // between Thread.init and the closure body — without that, the
        // main actor's `runLoopReady.wait()` would deadlock waiting for
        // a signal that never arrives.
        let readySignal = runLoopReady
        let thread = Thread { [weak self] in
            var setupCompleted = false
            defer { if !setupCompleted { readySignal.signal() } }
            guard let self, let tap = self.tap else { return }
            let rl = CFRunLoopGetCurrent()
            self.runLoop = rl
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            setupCompleted = true
            readySignal.signal()
            Self.log.info("hotkey runloop started (binding=\(self.binding.code, privacy: .public))")
            CFRunLoopRun()
            // CFRunLoopRun returns once stop() has scheduled CFRunLoopStop
            // on this runloop. The closure exits, the strong `self`
            // capture is released, and the thread terminates.
            Self.log.info("hotkey runloop exited (binding=\(self.binding.code, privacy: .public))")
        }
        thread.name = "app.notype.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        // Block until the tap thread has set up the runloop + source.
        // Without this, a stop() called immediately after start() would
        // race the setup and leak the tap (no runloop to schedule
        // CFRunLoopStop on). In practice start() is called from init
        // and stop() from a user-driven rebind much later, but the
        // synchronisation is cheap and removes the race entirely.
        runLoopReady.wait()

        return true
    }

    /// Tear down the tap, the runloop source, and stop the dedicated
    /// runloop so the thread exits and the `HotkeyMonitor` instance can
    /// be deallocated.
    ///
    /// Required for the rebind path (`AppState.applyHotkeyBinding(_:)`):
    /// dropping the strong reference alone is NOT enough because the
    /// tap thread's closure captures `self` strongly via `guard let self`
    /// and never returns until `CFRunLoopRun` does. Without `stop()` the
    /// old tap keeps firing for its previously-bound key in parallel
    /// with the freshly-installed monitor for the new binding.
    func stop() {
        // Flip the active flag first so any press/release Tasks already
        // queued on the main actor short-circuit before invoking the
        // callback. Without this, a press dispatched microseconds before
        // `stop()` could fire `onPress` against the NEW monitor's
        // session wiring during a rebind.
        isActive = false
        guard let tap, let runLoop else { return }
        // Disable immediately so no further callbacks fire while we tear
        // down. Thread-safe per Apple's docs.
        CGEvent.tapEnable(tap: tap, enable: false)
        // Schedule the rest on the tap's own runloop so we don't fight
        // an in-flight callback. CFRunLoopStop then unwinds CFRunLoopRun.
        let source = self.runLoopSource
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
        self.tap = nil
        self.runLoopSource = nil
        self.runLoop = nil
        self.thread = nil
    }

    /// Pure helper for testing the bit math without driving a real tap.
    /// Kept on the type for backwards-compat with `HotkeyMonitorTests`;
    /// callers that need to test a different binding can use
    /// `detectTransition(prev:curr:bit:)` directly.
    static func detectTransition(prev: UInt64, curr: UInt64) -> Transition {
        detectTransition(prev: prev, curr: curr, bit: rightOptionBit)
    }

    static func detectTransition(prev: UInt64, curr: UInt64, bit: UInt64) -> Transition {
        let p = (prev & bit) != 0
        let c = (curr & bit) != 0
        switch (p, c) {
        case (false, true):  return .pressed
        case (true,  false): return .released
        default:             return .none
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.warning("CGEventTap disabled (\(type.rawValue, privacy: .public)); re-enabling")
            // Reset state machines that depend on observing matched
            // press/release pairs. If a keyUp landed during the disabled
            // window, `nonModifierHeld` would stay stuck at `true` and
            // the hotkey would silently stop firing until app restart;
            // `previousFlags` would carry a phantom prior-bit value into
            // the next flagsChanged transition.
            nonModifierHeld = false
            previousFlags = 0
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            // Escape cancels an in-flight recording session. AppState
            // gates on `currentSession != nil` so a stray Escape press
            // when no session is running is a harmless no-op. The event
            // still passes through to the focused app (`.listenOnly`).
            if keycode == Self.escapeKeyCode {
                let onEscape = self.onEscape
                Task { @MainActor [weak self] in
                    guard self?.isActive == true else { return }
                    onEscape()
                }
                return
            }

            // Non-modifier binding: detect the bound key's first press.
            // macOS sends repeated keyDown events while the key is held;
            // we collapse them with `nonModifierHeld` so the recording
            // session sees exactly one press/release pair.
            if let vk = binding.virtualKeyCode, keycode == vk, !nonModifierHeld {
                nonModifierHeld = true
                let onPress = self.onPress
                Task { @MainActor [weak self] in
                    guard self?.isActive == true else { return }
                    onPress()
                }
            }
            return
        }

        if type == .keyUp {
            // Non-modifier binding: release.
            if let vk = binding.virtualKeyCode, keycode == vk, nonModifierHeld {
                nonModifierHeld = false
                let onRelease = self.onRelease
                Task { @MainActor [weak self] in
                    guard self?.isActive == true else { return }
                    onRelease()
                }
            }
            return
        }

        guard type == .flagsChanged else { return }

        // Modifier binding: bit transition on the configured device-side
        // mask. Non-modifier bindings still see flagsChanged here (any
        // press of e.g. Option fires it) but they have no `modifierBit`,
        // so the guard below short-circuits.
        guard let bit = binding.modifierBit else { return }

        let flags = event.flags.rawValue
        let prev  = previousFlags
        previousFlags = flags

        switch Self.detectTransition(prev: prev, curr: flags, bit: bit) {
        case .pressed:
            let onPress = self.onPress
            Task { @MainActor [weak self] in
                guard self?.isActive == true else { return }
                onPress()
            }
        case .released:
            let onRelease = self.onRelease
            Task { @MainActor [weak self] in
                guard self?.isActive == true else { return }
                onRelease()
            }
        case .none:
            break
        }
    }
}
