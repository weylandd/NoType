import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Global push-to-talk hotkey monitor.
///
/// Installs a `CGEventTap` for `flagsChanged` on a dedicated thread+runloop and
/// dispatches press / release of the configured modifier (default: Right Option)
/// to the main actor.
///
/// `@unchecked Sendable`: `previousFlags` is touched only on the tap thread;
/// `tap`/`runLoopSource`/`thread` are immutable after `start()`; the closures
/// are `@Sendable`.
final class HotkeyMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "hotkey")

    /// IOKit per-device-side modifier bits in `CGEventFlags.rawValue`.
    /// Right Option = `NX_DEVICERALTKEYMASK` (0x40); left = 0x20.
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

    private let onPress:   @MainActor @Sendable () -> Void
    private let onRelease: @MainActor @Sendable () -> Void
    private let onEscape:  @MainActor @Sendable () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var previousFlags: UInt64 = 0

    init(
        onPress:   @escaping @MainActor @Sendable () -> Void,
        onRelease: @escaping @MainActor @Sendable () -> Void,
        onEscape:  @escaping @MainActor @Sendable () -> Void
    ) {
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

        // We listen to flagsChanged (Right Option press/release) and keyDown
        // (Escape for cancel). `.listenOnly` means we never consume — every
        // keystroke still reaches the focused app. The added keyDown volume
        // is fine in practice; we filter to keycode 53 inside the callback.
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
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

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.log.info("hotkey runloop started")
            CFRunLoopRun()
        }
        thread.name = "app.notype.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        return true
    }

    /// Pure helper for testing the bit math without driving a real tap.
    static func detectTransition(prev: UInt64, curr: UInt64) -> Transition {
        let p = (prev & rightOptionBit) != 0
        let c = (curr & rightOptionBit) != 0
        switch (p, c) {
        case (false, true):  return .pressed
        case (true,  false): return .released
        default:             return .none
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.warning("CGEventTap disabled (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown {
            // Escape cancels an in-flight recording session. AppState
            // gates on `currentSession != nil` so a stray Escape press
            // when no session is running is a harmless no-op. The event
            // still passes through to the focused app (`.listenOnly`).
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == Self.escapeKeyCode {
                let onEscape = self.onEscape
                Task { @MainActor in onEscape() }
            }
            return
        }

        guard type == .flagsChanged else { return }

        let flags = event.flags.rawValue
        let prev  = previousFlags
        previousFlags = flags

        switch Self.detectTransition(prev: prev, curr: flags) {
        case .pressed:
            let onPress = self.onPress
            Task { @MainActor in onPress() }
        case .released:
            let onRelease = self.onRelease
            Task { @MainActor in onRelease() }
        case .none:
            break
        }
    }
}
