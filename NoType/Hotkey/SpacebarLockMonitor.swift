import AppKit
import ApplicationServices
import Foundation
import OSLog
import os

/// Secondary `CGEventTap` installed for the duration of a recording
/// session to listen for **Space pressed while the recording hotkey
/// is held**. When that combination fires, the session is "locked"
/// (same effect as a double-tap-lock) and the Space event is
/// consumed so a literal space doesn't land in the focused text
/// field.
///
/// Narrow-scope weakening of `Hotkey/CLAUDE.md` invariant 2: the
/// primary hotkey tap stays `.listenOnly`; this dedicated tap is the
/// only `.defaultTap` in the project, and it consumes exactly one
/// keycode (49 = Space) under exactly one condition (predicate
/// returns true). Mode-less by design — Hold+Space works alongside
/// hold-to-record and double-tap-to-lock for any non-Space recording
/// hotkey.
///
/// Lifecycle mirrors `HotkeyMonitor`: dedicated thread + runloop,
/// `start()` blocks until the runloop is set up, `stop()` tears down
/// the tap + unwinds the runloop. `@unchecked Sendable` for the same
/// reasons as `HotkeyMonitor`.
final class SpacebarLockMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.notype", category: "hotkey")

    /// `kVK_Space` virtual key code.
    private static let spaceKeyCode: Int64 = 49

    /// Sendable predicate the tap thread asks before deciding whether
    /// to consume a Space press. Returns `true` only when the user
    /// has the recording hotkey actively held AND the session is in
    /// `.recording` state AND it's NOT already locked. AppState
    /// provides this by reading from a lock-protected snapshot.
    private let shouldLockOnSpace: @Sendable () -> Bool

    /// Fired on the main actor when a Space press IS consumed by
    /// this tap. AppState uses it to flip `lockedRecording = true`.
    private let onLock: @MainActor @Sendable () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var isActive: Bool = true

    init(
        shouldLockOnSpace: @escaping @Sendable () -> Bool,
        onLock: @escaping @MainActor @Sendable () -> Void
    ) {
        self.shouldLockOnSpace = shouldLockOnSpace
        self.onLock = onLock
    }

    /// Install the secondary tap. Returns `false` if Accessibility
    /// isn't granted (shouldn't happen — `installHotkeyIfPossible`
    /// already gates on the same predicate before constructing this).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else {
            Self.log.warning("spacebar-lock: AX not trusted; skipping install")
            return false
        }

        // We only care about keyDown for keycode 49 (Space). The mask
        // is kept narrow so the tap thread does the minimum work per
        // event.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<SpacebarLockMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // `.defaultTap` so we can return `nil` and the event
            // doesn't reach the focused app. Narrow-scope: we only
            // consume keycode 49 under one specific predicate.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.log.error("spacebar-lock: CGEvent.tapCreate returned nil")
            return false
        }

        self.tap = newTap

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
            Self.log.info("spacebar-lock runloop started")
            CFRunLoopRun()
            Self.log.info("spacebar-lock runloop exited")
        }
        thread.name = "app.notype.hotkey.spacebar"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        runLoopReady.wait()
        return true
    }

    /// Tear down the tap + unwind the dedicated runloop. Mirrors
    /// `HotkeyMonitor.stop()`.
    func stop() {
        isActive = false
        guard let tap, let runLoop else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
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

    // MARK: - Tap callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable on the same disable signals HotkeyMonitor handles
        // — keeps the secondary tap alive through a transient stall.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.warning("spacebar-lock tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput", privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keycode == Self.spaceKeyCode else {
            return Unmanaged.passUnretained(event)
        }
        // Space pressed. Ask the predicate — only consume when the
        // user has the recording hotkey held AND a session is active
        // AND it's not already locked. Otherwise let Space through
        // (normal typing).
        guard shouldLockOnSpace() else {
            return Unmanaged.passUnretained(event)
        }

        // Consume the event AND fire the lock callback on the main
        // actor. The `isActive` guard mirrors HotkeyMonitor's pattern
        // — a callback queued microseconds before `stop()` must not
        // fire `onLock` against a being-torn-down session.
        let onLock = self.onLock
        Task { @MainActor [weak self] in
            guard self?.isActive == true else { return }
            onLock()
        }
        return nil
    }
}
