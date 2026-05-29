import AppKit
import Observation
import os
import OSLog
import SwiftUI

enum RecordingState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case sending
    case error(String)
}

@MainActor
@Observable
final class AppState {
    @ObservationIgnored private static let log = Logger(subsystem: "app.notype", category: "appstate")

    var recordingState: RecordingState = .idle
    var history: [HistoryEntry] = []

    /// Cross-window tab navigation flag. Set by surfaces outside the
    /// main window (e.g. popover gear → Settings) when they want the
    /// main window to open on a specific tab. `MainWindowView`
    /// unconditionally reads-then-clears this on `.onAppear` and
    /// `scenePhase == .active`; non-nil values land in `selectedTab`.
    /// Clear-first-apply-second is deliberate per plan §270 — prevents
    /// a flag set hours ago from hijacking an unrelated window-open
    /// trigger (e.g. a Sparkle banner click landing on Settings
    /// instead of the update detail).
    var pendingTabSelection: MainTab?

    /// Deep-link into a Settings sub-pane (e.g. the missing-API-key
    /// HUD's "Open Settings" button landing directly on API & Usage,
    /// not the default General pane). Consumed by `SettingsTabView`
    /// with the same clear-first-apply-second discipline as
    /// `pendingTabSelection`.
    var pendingSettingsCategory: SettingsCategory?

    /// Bridge for SwiftUI's `@Environment(\.openWindow)` into AppState.
    /// AppState is not a SwiftUI View and can't read the environment
    /// directly, so `MenuBarIcon`'s `.task` (always alive once
    /// onboarding completes — `NoTypeApp` suppresses the entire
    /// `MenuBarExtra` during onboarding) injects the closure on first
    /// appearance. Mirrors the post-init injection patterns already
    /// used for `NoTypeAppDelegate.terminationHandler` and
    /// `AppCategorizer.onAssignmentChanged`.
    ///
    /// Callers should prefer raising an already-created window via
    /// `NSApp.windows` first and fall through to this closure for the
    /// lazy-Window-scene case — see `NoTypeErrorKind.retryHandler` for
    /// the canonical pattern.
    ///
    /// `nil` window: during onboarding `MenuBarExtra` is suppressed so
    /// this slot is unset, but `handleHotkeyPress` also short-circuits
    /// to `onboardingHotkeyPressObserver`, so error HUDs that would
    /// invoke this closure cannot fire in that state.
    @ObservationIgnored
    var openMainWindowRequest: (() -> Void)?

    /// Lifetime aggregate of every recorded session — survives the
    /// 10-entry cap on `history`. Source of truth for Home tab stats
    /// (words/time saved/WPM), the top-apps panel, and the activity
    /// heatmap. Mirror of `StatsStore`.
    var statsSummary: StatsSnapshot = .empty

    /// Global user-supplied instruction (the textarea on the Instructions
    /// tab). Empty string == not set; the prompt section is omitted from
    /// the Gemini request when empty. Mirror of `InstructionsStore`.
    var userInstruction: String = ""

    /// Per-category prompt overrides. Lookup falls back to
    /// `AppCategory.defaultPrompt` when a category isn't present here.
    var categoryPromptOverrides: [AppCategory: String] = [:]

    /// Cached app→category assignments. Source of truth is the on-disk
    /// `InstructionsStore`; this is the main-actor mirror for SwiftUI.
    var categoryAssignments: [String: AppCategoryAssignment] = [:]

    /// Personal-dictionary entries — both user-typed and auto-extracted.
    /// Source of truth is `DictionaryStore` (`dictionary.json`); this is
    /// the main-actor mirror for the Dictionary tab and the cache-prefix
    /// section built by `currentDictionaryContext()` at session start.
    var dictionaryEntries: [DictionaryEntry] = []

    /// Replacement pairs applied to the final transcript at paste time
    /// (`TextReplacementEngine.apply`). Pure client-side — never sent
    /// to Gemini.
    var dictionaryReplacements: [DictionaryReplacement] = []

    /// Master toggle for the `User dictionary:` Gemini prompt section.
    /// When `false`, `currentDictionaryContext()` ships empty
    /// `activeEntries` (so the section body renders as `(empty)` —
    /// preserving the cache-prefix shape, see ADR-016) and post-session
    /// auto-harvest is skipped. The Dictionary tab keeps full
    /// add/remove access so users can manage entries while disabled.
    /// Replacement pairs (`Auto-replacement` panel) are intentionally
    /// NOT gated — they're a separate client-side concern.
    var dictionaryEnabled: Bool = UserDefaults.standard.object(forKey: AppState.dictionaryEnabledKey) as? Bool ?? true

    /// UserDefaults key for the dictionary master toggle. Read with
    /// `object(forKey:) as? Bool` so the absent-key path defaults to
    /// `true` (existing installs keep their previous behaviour — words
    /// continue to ship to Gemini).
    @ObservationIgnored fileprivate static let dictionaryEnabledKey = "notype.dictionaryEnabled"

    /// BCP-47 language codes the user wants Gemini to bias transcription
    /// towards. Persisted under `notype.outputLanguages` as a plist
    /// `[String]`. Mirrored into `ContextSnapshot.userLanguages` at the
    /// start of each `RecordingSession`, then frozen for that session
    /// (mirrors the `DictionaryContext` sourcing pattern — see plan
    /// `2026-05-18-001-feat-settings-screen-plan.md` §584-646). Default
    /// is empty → the `User languages:` cache-prefix section ships
    /// with body `(empty)`.
    var outputLanguages: [String] = (UserDefaults.standard.array(forKey: AppState.outputLanguagesKey) as? [String]) ?? [] {
        didSet {
            UserDefaults.standard.set(outputLanguages, forKey: AppState.outputLanguagesKey)
        }
    }

    @ObservationIgnored fileprivate static let outputLanguagesKey = "notype.outputLanguages"

    @ObservationIgnored private var hotkeyMonitor: HotkeyMonitor?

    /// Current hotkey binding. Read at init from `UserDefaults` (falls
    /// back to `.default` = Right Option). `applyHotkeyBinding(_:)` swaps
    /// in a new binding live — used by the onboarding remap UI and the
    /// future Settings shortcut picker.
    @ObservationIgnored private(set) var hotkeyBinding: HotkeyBinding = .load()

    /// Cancel shortcut for an in-flight recording session. Read at init
    /// from `UserDefaults` (falls back to Escape). `applyCancelHotkeyBinding(_:)`
    /// swaps it live, rebuilding the underlying `HotkeyMonitor` against
    /// the new binding. Persistence key: `notype.cancelHotkey.bindingCode`.
    /// Restricted to non-modifier keys (see `HotkeyBinding.isAllowedAsCancelBinding`).
    @ObservationIgnored private(set) var cancelHotkeyBinding: HotkeyBinding = AppState.loadCancelHotkey()

    @ObservationIgnored static let cancelHotkeyDefaultsKey = "notype.cancelHotkey.bindingCode"

    fileprivate static func loadCancelHotkey() -> HotkeyBinding {
        let stored = UserDefaults.standard.string(forKey: cancelHotkeyDefaultsKey) ?? ""
        let candidate = HotkeyBinding(code: stored.isEmpty ? "Escape" : stored)
        return candidate.isAllowedAsCancelBinding ? candidate : HotkeyBinding(code: "Escape")
    }
    @ObservationIgnored private let permissions: PermissionsViewModel
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private let gemini: GeminiClient
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private let statsStore: StatsStore
    @ObservationIgnored private let instructionsStore: InstructionsStore
    @ObservationIgnored private let appCategorizer: AppCategorizer
    @ObservationIgnored private let dictionaryStore: DictionaryStore
    @ObservationIgnored private let onboarding: OnboardingState
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    /// While the wizard is showing step 4 (hotkey check), it sets these
    /// so a Right Option press fires its UI feedback instead of starting
    /// a recording session. Cleared on disappear.
    @ObservationIgnored var onboardingHotkeyPressObserver:   (@MainActor () -> Void)?
    @ObservationIgnored var onboardingHotkeyReleaseObserver: (@MainActor () -> Void)?

    /// Long-lived Silero VAD. The CoreML load is non-trivial (~50–150 ms);
    /// keep one instance for the app lifetime and reset its state at the
    /// start of each session.
    @ObservationIgnored private var vad: SileroVAD?
    @ObservationIgnored private var vadLoadFailureLogged = false

    @ObservationIgnored private var currentSession: RecordingSession?

    // MARK: - Hotkey state machine

    /// Threshold below which a press → release pair counts as a *tap*
    /// (i.e. user briefly tapped the hotkey, didn't hold). Holds longer
    /// than this trigger the normal press-and-release flow.
    @ObservationIgnored private let tapMaxDuration:    TimeInterval = 0.20
    /// How long after a tap-release we wait for a second press before
    /// concluding it was a single accidental tap and stopping the
    /// session.
    @ObservationIgnored private let doubleTapWindow:   TimeInterval = 0.30

    /// When the current press began (set on press, cleared on release).
    @ObservationIgnored private var pressStartedAt: Date?
    /// True while we're waiting to see if the user double-taps.
    /// Recording is still running during this window — we just haven't
    /// committed to ending it yet.
    @ObservationIgnored private var awaitingSecondTap = false
    /// Cancels the pending "no second tap arrived → stop the session"
    /// timer when a second press *does* arrive.
    @ObservationIgnored private var doubleTapTimeout: Task<Void, Never>?
    /// True between a successful double-tap and the next press. While
    /// locked, releases of the hotkey are ignored — the session keeps
    /// running. Next press flips back to false and stops the session.
    @ObservationIgnored private var lockedRecording = false

    /// Lock-protected mirror of "Hold+Space lock should fire right
    /// now": the recording hotkey is held, the session is in
    /// `.recording`, and we aren't already locked (and the hotkey
    /// isn't Space itself — pressing your own hotkey-as-Space would
    /// be ambiguous). Read from the secondary `SpacebarLockMonitor`
    /// tap thread; written from `@MainActor`-isolated handlers via
    /// `updateSpacebarLockEnabled()` whenever any input to the
    /// predicate changes.
    @ObservationIgnored fileprivate nonisolated let spacebarLockEnabled =
        OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Secondary `.defaultTap` CGEventTap installed for the duration
    /// of an active session. Consumes Space when the predicate above
    /// reads true and fires `handleSpacebarLockTrigger()`. See
    /// `NoType/Hotkey/SpacebarLockMonitor.swift` for the rationale
    /// behind the narrow invariant-2 weakening.
    @ObservationIgnored private var spacebarLockMonitor: SpacebarLockMonitor?

    /// Cached Gemini API key — populated on first access from `SecretStore`.
    /// Re-reads only happen via `updateAPIKey`.
    @ObservationIgnored private var cachedAPIKey: String?
    @ObservationIgnored private var apiKeyLoaded = false

    /// "Prevent sleep while recording" toggle from the Settings → General
    /// section. Default `false` — most sessions are short enough that
    /// the system never reaches its idle-sleep threshold. UserDefaults-
    /// backed via `notype.preventSleepDuringRecording`. When true,
    /// `RecordingSession.start()` reaches into `acquireSleepAssertionIfNeeded()`
    /// and `stop()` / `cancel()` / terminal-error paths release.
    var preventSleepDuringRecording: Bool {
        didSet {
            UserDefaults.standard.set(
                preventSleepDuringRecording,
                forKey: Self.preventSleepKey
            )
        }
    }

    @ObservationIgnored fileprivate static let preventSleepKey = "notype.preventSleepDuringRecording"

    /// `@MainActor`-isolated owner of the currently-held `SleepAssertion`.
    /// Single source of truth — kept on `AppState` rather than
    /// `RecordingSession` because the session is a value-style type that
    /// can be copied across partial-recovery flows; double-releasing the
    /// IOKit handle from two copies would log a warning at best.
    @ObservationIgnored private var activeSleepAssertion: SleepAssertion?

    /// Music-interruption mode from Settings → Recording. Default `.none`.
    /// `.mute` toggles `kAudioDevicePropertyMute` on the system
    /// default output for the recording-session duration and restores
    /// the prior state on stop. (An older `.pause` toggle mode was
    /// removed — it started stopped/paused media; see
    /// `MusicInterruption`.) Persisted as the `Mode.rawValue` string
    /// under `notype.musicInterruption`; an unknown stored value
    /// (e.g. a legacy `"pause"`) decodes to `.none` in `init`.
    var musicInterruptionMode: MusicInterruption.Mode {
        didSet {
            UserDefaults.standard.set(
                musicInterruptionMode.rawValue,
                forKey: MusicInterruption.Mode.userDefaultsKey
            )
        }
    }

    /// Transcription model from Settings → API & Usage. Default
    /// `.flashLite`. Frozen into each `RecordingSession` at start and
    /// threaded into every Gemini transcription call (the classifier
    /// stays on Flash-Lite regardless). Persisted as the `rawValue`
    /// string under `notype.geminiModel`; an unknown stored value
    /// decodes to `.flashLite` in `init`.
    var geminiModel: GeminiModel {
        didSet {
            UserDefaults.standard.set(
                geminiModel.rawValue,
                forKey: GeminiModel.userDefaultsKey
            )
        }
    }

    /// `@MainActor`-isolated owner of the currently-held music-
    /// interruption assertion. Single-ownership / RAII shape mirrors
    /// `activeSleepAssertion`. Created in `acquireMusicInterruptionIfNeeded`,
    /// released in the three terminal session-end paths.
    @ObservationIgnored private var activeMusicInterruption: MusicInterruption?

    /// `SMAppService.mainApp` wrapper for the Settings → General →
    /// "Open at login" toggle. Owned at the AppState layer so the
    /// status mirror survives Settings tab transitions and is
    /// observable from anywhere in the SwiftUI tree.
    let loginItemController: LoginItemController

    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    init(
        permissions: PermissionsViewModel,
        hud: HUDController,
        gemini: GeminiClient,
        historyStore: HistoryStore,
        statsStore: StatsStore,
        instructionsStore: InstructionsStore,
        appCategorizer: AppCategorizer,
        dictionaryStore: DictionaryStore,
        onboarding: OnboardingState
    ) {
        self.permissions = permissions
        self.hud = hud
        self.gemini = gemini
        self.historyStore = historyStore
        self.statsStore = statsStore
        self.instructionsStore = instructionsStore
        self.appCategorizer = appCategorizer
        self.dictionaryStore = dictionaryStore
        self.onboarding = onboarding
        self.preventSleepDuringRecording = UserDefaults.standard.bool(forKey: Self.preventSleepKey)
        // Music interruption defaults to `.none` — engaging it
        // affects all running apps' audio (Mute) or pokes media keys
        // system-wide (Pause), so it's opt-in.
        let storedMode = UserDefaults.standard.string(forKey: MusicInterruption.Mode.userDefaultsKey)
            .flatMap(MusicInterruption.Mode.init(rawValue:))
        self.musicInterruptionMode = storedMode ?? .none
        // Transcription model: persisted choice, else the Flash-Lite
        // default. Unknown stored values (renamed/removed cases) fall
        // back to `.flashLite` via `GeminiModel.fallback`.
        let storedModel = UserDefaults.standard.string(forKey: GeminiModel.userDefaultsKey)
            .flatMap(GeminiModel.init(rawValue:))
        self.geminiModel = storedModel ?? GeminiModel.fallback
        self.loginItemController = LoginItemController()

        Task { @MainActor [weak self] in
            await self?.refreshHistory()
        }
        Task { @MainActor [weak self, statsStore] in
            let snap = await statsStore.summary()
            self?.statsSummary = snap
        }

        // Prime the Instructions mirror + wire the categorizer's
        // background-write notification back to this main-actor state.
        // Both legs run as separate fire-and-forget tasks so neither
        // nests `[weak self]` captures (Swift 6 strict-concurrency
        // doesn't allow the inner closure to re-capture an outer
        // weak-self).
        Task { @MainActor [weak self, instructionsStore] in
            let snap = await instructionsStore.snapshot()
            self?.applyInstructionsSnapshot(snap)
        }
        Task { @MainActor [weak self] in
            await self?.wireAssignmentCallback()
        }

        // Dictionary mirror — snapshot-prime only. Harvest writes go
        // through `harvestDictionaryIfRoom` which calls back into
        // `applyDictionarySnapshot` directly, no extractor callback to
        // wire up.
        Task { @MainActor [weak self, dictionaryStore] in
            let snap = await dictionaryStore.snapshot()
            self?.applyDictionarySnapshot(snap)
        }

        // Apply the current accessibility state synchronously so the
        // hotkey is installed (or known-missing) before the first observed
        // change. Mirrors `removeDuplicates` semantics on the Combine path.
        applyAccessibilityState()

        // Install/uninstall the hotkey based on Accessibility, and reconcile
        // the permission-card HUD when either Accessibility or Microphone
        // changes. macOS silently disables an existing CGEventTap when the
        // permission is revoked, so we drop the old monitor and re-create
        // it on next grant. We don't auto-show cards — only explicit
        // triggers (launch / menu-bar click / hotkey press for microphone)
        // do that.
        observationTasks.append(
            Task { @MainActor [weak self] in
                await self?.observePermissions()
            }
        )

        // Initial show at launch. Suppressed while the onboarding wizard
        // is up; the wizard owns permission prompting until the user
        // finishes it.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.onboarding.isComplete else { return }
            if !self.permissions.allGranted {
                self.hud.presentMissing(Set(PermissionKind.allCases))
            }
        }

        // Pre-load Silero so the first hotkey press doesn't pay the model
        // load cost. Failure here is not fatal — we surface it on first
        // session attempt instead.
        Task { @MainActor [weak self] in
            do {
                let v = try SileroVAD()
                self?.vad = v
            } catch {
                Self.log.error("Silero load failed at startup: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    deinit {
        for task in observationTasks { task.cancel() }
    }

    // MARK: - Observation of PermissionsViewModel

    /// Synchronous accessibility-state application — install or uninstall
    /// the hotkey to match the current permission. Called once at init
    /// and once after every change observed by `observePermissions()`.
    private func applyAccessibilityState() {
        if permissions.accessibility.isGranted {
            installHotkeyIfPossible()
        } else {
            uninstallHotkey()
        }
    }

    /// Long-lived observation loop over `permissions.accessibility` and
    /// `.microphone`. Each turn of the loop:
    ///
    /// 1. Snapshots both values.
    /// 2. Suspends inside `withObservationTracking` on a checked
    ///    continuation that resumes on the *next* mutation of either
    ///    tracked property.
    /// 3. Wakes up, re-snapshots, and re-runs the side effects only when
    ///    a value actually changed (mirrors `removeDuplicates` from the
    ///    prior Combine-based version).
    ///
    /// Cancelling the task (via deinit) cancels the continuation cleanly.
    private func observePermissions() async {
        var lastAx = permissions.accessibility
        var lastMic = permissions.microphone
        // Reconcile HUD against the initial values once.
        reconcilePermissionHUD(ax: lastAx, mic: lastMic)
        while !Task.isCancelled {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = self.permissions.accessibility
                    _ = self.permissions.microphone
                } onChange: {
                    cont.resume()
                }
            }
            if Task.isCancelled { return }
            let ax = permissions.accessibility
            let mic = permissions.microphone
            if ax != lastAx {
                applyAccessibilityState()
            }
            if ax != lastAx || mic != lastMic {
                reconcilePermissionHUD(ax: ax, mic: mic)
            }
            lastAx = ax
            lastMic = mic
        }
    }

    private func reconcilePermissionHUD(ax: PermissionStatus, mic: PermissionStatus) {
        if ax.isGranted && mic.isGranted {
            hud.hidePermissionsHUD()
        } else {
            hud.reconcileGranted()
        }
    }

    // MARK: - User-facing triggers

    /// Called when the user opens the menu-bar popover.
    func handleMenuBarOpened() {
        guard onboarding.isComplete else { return }
        if !permissions.allGranted {
            hud.presentMissing(Set(PermissionKind.allCases))
        }
    }

    func refreshHistory() async {
        history = await historyStore.allEntries()
    }

    /// Trailing audio samples from the in-flight recording session, or
    /// an empty array if there is none. Driven by the recording HUD's
    /// spectrum meter at ~30 fps.
    func recentAudioSamples(count: Int) -> [Float] {
        currentSession?.recentSamples(count: count) ?? []
    }

    /// Remove a single history entry from the on-disk store and the
    /// in-memory mirror. Called by the row's trash button.
    func deleteHistoryEntry(id: UUID) {
        // Optimistic local update so the row disappears immediately.
        history.removeAll { $0.id == id }
        Task { [historyStore] in
            await historyStore.remove(id: id)
        }
    }

    /// Wipe every transcript from the on-disk history file and the
    /// in-memory mirror. Driven by Settings → System → "Delete all
    /// transcripts" (plan §584-646). Stats are intentionally NOT
    /// touched — usage aggregates (word count, session count, token
    /// totals, per-app breakdown) survive the wipe per the
    /// no-telemetry carve-out. The wording in the confirmation dialog
    /// names this explicitly so users who inspect `stats.json` aren't
    /// surprised. Fire-and-forget disk write mirrors
    /// `deleteHistoryEntry`.
    func deleteAllHistory() {
        history.removeAll()
        Task { [historyStore] in
            await historyStore.deleteAll()
        }
    }

    /// Wipe every aggregate stat (totals, day / app / day×app buckets,
    /// token counters). Driven by Settings → "Delete all analytics".
    /// Symmetric to `deleteAllHistory()` — independent so the user
    /// can scrub one without the other.
    ///
    /// Race shape we have to defend against: `finalizeRecording()`
    /// fires `Task { record(...); MainActor.run { statsSummary = snap } }`.
    /// The `StatsStore` actor serialises `record()` and `deleteAll()` on
    /// disk + actor cache, but the `MainActor` mirror write-back from a
    /// concurrent `record()` continuation can land *after* an optimistic
    /// `statsSummary = .empty`, re-publishing the just-deleted snapshot to
    /// Home + Token usage. So we do NOT pre-clear the mirror — instead we
    /// await the actor wipe and then assign the actor-confirmed empty
    /// snapshot on the same MainActor hop. If a concurrent `record()`
    /// raced ahead and updated the mirror in between, our post-`deleteAll`
    /// assignment still wins because we run after the actor confirmed the
    /// disk-truth.
    func deleteAllStats() {
        Task { [statsStore] in
            let empty = await statsStore.deleteAll()
            await MainActor.run { [weak self] in
                self?.statsSummary = empty
            }
        }
    }

    // MARK: - API key

    /// Reads the cached key, falling back to env var + Keychain on first
    /// access. Subsequent calls are free.
    var currentAPIKey: String? {
        if !apiKeyLoaded {
            cachedAPIKey = SecretStore.loadFromEnvOrFile()
            apiKeyLoaded = true
        }
        return cachedAPIKey
    }

    /// Free check that the supplied key is accepted by the Gemini API.
    /// Throws on 401/403 / network error. Used by the onboarding wizard
    /// before saving the key.
    func validateGeminiKey(_ key: String) async throws {
        try await gemini.validateKey(key)
    }

    /// Persists the key to Keychain (or deletes it if blank) and atomically
    /// updates the in-memory cache. Bypasses re-reading after Save.
    func updateAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try SecretStore.deleteGeminiKey()
            cachedAPIKey = nil
        } else {
            try SecretStore.saveGeminiKey(trimmed)
            cachedAPIKey = trimmed
        }
        apiKeyLoaded = true
    }

    // MARK: - Hotkey

    private func installHotkeyIfPossible() {
        guard hotkeyMonitor == nil else { return }
        let monitor = HotkeyMonitor(
            binding:       hotkeyBinding,
            cancelBinding: cancelHotkeyBinding,
            onPress:   { [weak self] in self?.handleHotkeyPress() },
            onRelease: { [weak self] in self?.handleHotkeyRelease() },
            onEscape:  { [weak self] in self?.cancelRecording() }
        )
        if monitor.start() {
            hotkeyMonitor = monitor
            Self.log.info("hotkey installed (record=\(self.hotkeyBinding.code, privacy: .public) cancel=\(self.cancelHotkeyBinding.code, privacy: .public))")
        }
    }

    private func uninstallHotkey() {
        guard let monitor = hotkeyMonitor else { return }
        // Invalidate the tap + stop the dedicated runloop. Required for
        // the rebind path — dropping the strong reference alone leaks
        // the tap because the thread's `guard let self` strongly retains
        // the monitor across `CFRunLoopRun`. The AX-revoke path also
        // benefits: prior builds left a stranded runloop per revoke.
        monitor.stop()
        hotkeyMonitor = nil
        // The secondary Hold+Space tap has no reason to outlive the
        // primary monitor — without an active recording-hotkey tap the
        // predicate can never become true. Tearing it down here covers
        // the AX-revoke-mid-session path explicitly: a stranded
        // `.defaultTap` consuming Space across the OS would be worse
        // than the recording outage itself. The call is idempotent.
        uninstallSpacebarLockTap()
        Self.log.info("hotkey uninstalled")
    }

    /// Outcome of applying a new recording binding. Mirror of
    /// `CancelBindingApplyResult` so the Settings rebind sheet
    /// handles both surfaces with the same `switch` shape and the
    /// user sees an inline reason for every rejection instead of
    /// a silent revert.
    enum HotkeyBindingApplyResult: Equatable, Sendable {
        case applied
        case noChange
        case rejectedDuringRecording
        case rejectedCollidesWithCancel
        case rejectedDisallowedKey
    }

    /// Persist a new hotkey binding and reinstall the monitor against it.
    /// Called by the onboarding shortcut screen's remap UI and the
    /// Settings → Shortcuts rebind sheet.
    ///
    /// Validation (in order, matches the cancel-binding side):
    ///   1. `isAllowedAsHotkey` — Escape / Power / CapsLock rejected
    ///      so the user can't accidentally pick a system key.
    ///   2. Collision vs `cancelHotkeyBinding.code` — without this,
    ///      `HotkeyMonitor.handle` would match the cancel keycode
    ///      before the press path and silently fire cancel instead
    ///      of starting a session.
    ///   3. `binding == hotkeyBinding` — `noChange` short-circuit.
    ///   4. Refused while a recording session is in flight — tearing
    ///      the monitor down mid-session drops the release event for
    ///      the previously-held key, which would orphan the session
    ///      in `.recording`/`.sending` with no path to finalize except
    ///      Esc. The UI also disables the Change button when
    ///      `recordingState != .idle`; this guard is defence-in-depth.
    @discardableResult
    func applyHotkeyBinding(_ binding: HotkeyBinding) -> HotkeyBindingApplyResult {
        guard binding.isAllowedAsHotkey else { return .rejectedDisallowedKey }
        if binding.code == cancelHotkeyBinding.code {
            return .rejectedCollidesWithCancel
        }
        guard binding != hotkeyBinding else { return .noChange }
        guard case .idle = recordingState else {
            Self.log.warning("applyHotkeyBinding refused while recordingState != .idle")
            return .rejectedDuringRecording
        }
        hotkeyBinding = binding
        binding.save()
        // Re-create the underlying tap so the new binding's detection
        // path takes effect. `uninstallHotkey -> monitor.stop()`
        // invalidates the tap and unwinds the dedicated runloop; the
        // prior thread terminates cleanly (no leak).
        uninstallHotkey()
        installHotkeyIfPossible()
        return .applied
    }

    /// Outcome of applying a new cancel binding. Surfaces validation
    /// failure to the UI inline (refused mid-session, collision with
    /// the recording hotkey, unsupported key class). Mirrors the
    /// silent-refuse pattern of `applyHotkeyBinding(_:)` but with
    /// explicit feedback because the Settings sheet needs to tell
    /// the user *why* their pick was rejected.
    enum CancelBindingApplyResult: Equatable, Sendable {
        case applied
        case noChange
        case rejectedDuringRecording
        case rejectedCollidesWithRecordingHotkey
        case rejectedDisallowedKey
    }

    /// Persist a new cancel-recording binding and reinstall the
    /// underlying monitor. Refused mid-session for the same reason as
    /// `applyHotkeyBinding(_:)` — tearing the tap down drops the
    /// release event for any currently-held key. The cancel-vs-record
    /// collision check (`newBinding.code == hotkeyBinding.code`) is
    /// the only validation the recording-hotkey path doesn't need.
    @discardableResult
    func applyCancelHotkeyBinding(_ binding: HotkeyBinding) -> CancelBindingApplyResult {
        guard binding.isAllowedAsCancelBinding else { return .rejectedDisallowedKey }
        if binding.code == hotkeyBinding.code {
            return .rejectedCollidesWithRecordingHotkey
        }
        guard binding != cancelHotkeyBinding else { return .noChange }
        guard case .idle = recordingState else {
            Self.log.warning("applyCancelHotkeyBinding refused while recordingState != .idle")
            return .rejectedDuringRecording
        }
        cancelHotkeyBinding = binding
        UserDefaults.standard.set(binding.code, forKey: Self.cancelHotkeyDefaultsKey)
        // Rebuild monitor so the new cancel keycode takes effect.
        uninstallHotkey()
        installHotkeyIfPossible()
        // Defensive — cancel binding changes can flip the
        // Hold+Space gate (e.g. cancel = Space suppresses lock).
        // Rebind is refused mid-session, so in practice this just
        // keeps the predicate honest if the rebuild added a session.
        updateSpacebarLockEnabled()
        return .applied
    }

    private func handleHotkeyPress() {
        // Onboarding step 4 (hotkey check) intercepts presses to drive
        // its own UI without starting a recording session. The CGEventTap
        // is already installed (AX granted in step 2), so the press
        // arrives normally — we just short-circuit before the session
        // and missing-mic gates.
        if let observer = onboardingHotkeyPressObserver {
            observer()
            return
        }

        if !permissions.microphone.isGranted {
            // Accessibility must be granted for this callback to fire at all,
            // so the only thing that can be missing here is the microphone.
            hud.presentMissing([.microphone])
            return
        }

        // Tap-toggle state machine, layered on top of the press / release
        // flow:
        //
        //   • Press while locked → flip lock off, finalize the session.
        //   • Press inside the double-tap window → cancel the pending
        //     "stop after tap" timeout, set lockedRecording = true. The
        //     session is already running from the first tap and just
        //     keeps going.
        //   • Press from idle → standard flow, start a session and
        //     remember when the press began so the release handler can
        //     decide whether it was a tap or a hold.
        if lockedRecording {
            lockedRecording = false
            awaitingSecondTap = false
            doubleTapTimeout?.cancel()
            doubleTapTimeout = nil
            updateSpacebarLockEnabled()
            finalizeRecording()
            return
        }

        if awaitingSecondTap {
            doubleTapTimeout?.cancel()
            doubleTapTimeout = nil
            awaitingSecondTap = false
            lockedRecording = true
            Self.log.info("hotkey double-tap → locked recording")
            return
        }

        guard case .idle = recordingState else { return }

        // Screen Recording first-press gate. If TCC has never seen us (the
        // user skipped the optional onboarding card), the OCR fallback's
        // first call to ScreenCaptureKit can surface a system prompt mid-
        // session and break the recording flow. Surface the prompt here,
        // before any audio capture, and let the user decide. The next
        // press proceeds normally — at that point the status is granted
        // or denied, and the OCR limb behaves accordingly.
        if ScreenRecordingPermission.current() == .notDetermined {
            Self.log.info("hotkey: screen-recording not yet asked; deferring session to surface prompt")
            Task { await permissions.requestScreenRecording() }
            return
        }

        guard let apiKey = currentAPIKey, !apiKey.isEmpty else {
            surfaceError(.missingAPIKey)
            return
        }

        // Lazy retry of Silero load if startup pre-load failed.
        if vad == nil {
            do {
                vad = try SileroVAD()
            } catch {
                if !vadLoadFailureLogged {
                    Self.log.error("Silero load failed: \(error.localizedDescription, privacy: .public)")
                    vadLoadFailureLogged = true
                }
                surfaceError(.vadLoadFailed)
                return
            }
        }
        guard let vad else { return }

        let session = RecordingSession(
            recorder: AudioRecorder(),
            vad: vad,
            gemini: gemini,
            history: historyStore
        )

        let instructionsContext = currentInstructionsContext()
        let dictionaryContext = currentDictionaryContext()
        let userLanguagesFrozen = outputLanguages
        do {
            try session.start(
                apiKey: apiKey,
                instructions: instructionsContext,
                dictionary: dictionaryContext,
                userLanguages: userLanguagesFrozen,
                model: geminiModel
            )
        } catch {
            Self.log.error("session start failed: \(error.localizedDescription, privacy: .public)")
            surfaceError(.sessionStartFailed(error))
            return
        }

        // Fire-and-forget categorize when we haven't seen this bundle
        // yet. Doesn't block the session — the current request uses
        // whatever was cached (or `.uncategorized` if nothing was);
        // next session in this app sees the new assignment.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontmost.bundleIdentifier, !bundleID.isEmpty,
           categoryAssignments[bundleID] == nil {
            classifyAppInBackground(
                bundleID: bundleID,
                displayName: frontmost.localizedName ?? "Unknown"
            )
        }

        // Recording started successfully — clear any stale error HUD so
        // the user isn't looking at a "Couldn't reach Gemini" card while
        // their voice is being recorded.
        hud.hideErrorHUD()

        currentSession = session
        let startedAt = Date()
        pressStartedAt = startedAt
        recordingState = .recording(startedAt: startedAt)
        acquireSleepAssertionIfNeeded()
        acquireMusicInterruptionIfNeeded()
        installSpacebarLockTapIfNeeded()
        updateSpacebarLockEnabled()
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Active app"
        hud.showRecordingHUD(
            startedAt: startedAt,
            targetAppName: target,
            samplesProvider: { [weak self] in
                self?.recentAudioSamples(count: AudioSpectrum.fftLength) ?? []
            },
            onCancel: { [weak self] in self?.cancelRecording() }
        )
    }

    private func handleHotkeyRelease() {
        // Onboarding step 4 mirror of the press observer. Same rationale.
        if let observer = onboardingHotkeyReleaseObserver {
            observer()
            return
        }

        // Locked sessions don't react to releases — the user has
        // committed to "record until I tap again", so the session
        // stays alive. We still clear `pressStartedAt` + recompute
        // the Hold+Space predicate so the secondary tap stops
        // consuming Space the moment the user releases the hotkey.
        if lockedRecording {
            pressStartedAt = nil
            updateSpacebarLockEnabled()
            return
        }

        guard case .recording = recordingState else { return }

        let now = Date()
        let pressDuration = pressStartedAt.map { now.timeIntervalSince($0) } ?? .infinity
        pressStartedAt = nil
        updateSpacebarLockEnabled()

        // Hold release: standard end-of-session flow.
        if pressDuration > tapMaxDuration {
            finalizeRecording()
            return
        }

        // Tap release. Don't end the session yet — wait one
        // `doubleTapWindow` to see if a second press arrives and locks
        // the session in toggle mode. If not, end normally.
        awaitingSecondTap = true
        doubleTapTimeout?.cancel()
        doubleTapTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.doubleTapWindow ?? 0.3))
            guard let self, !Task.isCancelled else { return }
            guard self.awaitingSecondTap else { return }
            self.awaitingSecondTap = false
            self.finalizeRecording()
        }
    }

    /// Hand the in-flight session over to the transcribing HUD →
    /// paste pipeline. Shared between the hold-release path, the
    /// no-second-tap timeout, and the toggle-mode unlock.
    ///
    /// `currentSession` is intentionally kept non-nil while the state is
    /// `.sending` so the global Escape hotkey can still reach the session
    /// and abort the in-flight Gemini call. The completion paths below
    /// clear it via the `currentSession === session` identity guard, so a
    /// late-arriving result for a session the user has already cancelled
    /// (and replaced with a new one) can't clobber the new session.
    private func finalizeRecording() {
        guard case .recording = recordingState, let session = currentSession else { return }

        recordingState = .sending
        // Hotkey released → stop capturing *now* so the mic is truly
        // quiet before we lift the mute. Otherwise a few ms of
        // newly-unmuted speaker audio could bleed into the final chunk's
        // tail (the recorder keeps running until `recorder.stop()` inside
        // the async `session.stop()` below). `stopCapture()` is
        // idempotent with that later stop and leaves the PCM ring intact,
        // so the final-chunk tail is still harvested.
        session.stopCapture()
        // With the mic now quiet, lift any music-output mute immediately
        // rather than holding it through the Gemini transcription window
        // (dead time — nothing is being recorded). The sleep assertion is
        // NOT released here: it stays until the terminal arms below so the
        // Mac can't sleep mid-call. `releaseMusicInterruption()` is
        // idempotent, so the arms below no longer re-call it.
        releaseMusicInterruption()
        let target = session.sourceAppName ?? "the focused app"
        // Dismiss-only: the X button hides the HUD without cancelling the
        // in-flight Gemini call. Transcription continues and the paste
        // still fires when ready. Escape (handled globally via the
        // hotkey tap) does abort — see `cancelRecording`.
        hud.showTranscribingHUD(targetAppName: target)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entry = try await session.stop()
                // Capture the session's outcome summary BEFORE we
                // potentially drop the reference — used below to
                // surface a neutral "some parts didn't transcribe"
                // HUD when the pasted text contains `[…]` markers.
                let sessionSummary = session.summary
                // If Escape (or some other path) intervened while we were
                // awaiting stop(), state/HUD have already been reset and
                // `currentSession` either is nil or points to a *new*
                // session the user has since started. Don't touch either.
                guard self.currentSession === session, case .sending = self.recordingState else { return }
                self.currentSession = nil
                self.history.append(entry)
                if self.history.count > 10 {
                    self.history.removeFirst(self.history.count - 10)
                }
                self.recordingState = .idle
                self.lockedRecording = false
                self.releaseSleepAssertion()
                self.uninstallSpacebarLockTap()
                self.hud.hideTranscribingHUD()
                if sessionSummary.hasFailures {
                    Self.log.warning(
                        "session paste contains \(sessionSummary.failedChunkCount) failure marker(s) of \(sessionSummary.dispatchedChunkCount) chunk(s)"
                    )
                    self.surfaceError(.partialTranscription(summary: sessionSummary))
                }
                // Fold into lifetime stats — survives the history cap so
                // the Home tab's totals / top-apps / heatmap keep
                // accumulating beyond the rolling 10-entry window.
                // Token aggregates ride the same path (added in U5,
                // plan 2026-05-18-001) — `sessionSummary.tokens` is
                // already a per-session sum of successful Gemini
                // calls; failed (recoverable) chunks contribute zero.
                let tokens = sessionSummary.tokens
                let model = sessionSummary.model
                Task { [statsStore = self.statsStore] in
                    let snap = await statsStore.record(entry, tokens: tokens, model: model)
                    await MainActor.run { [weak self] in
                        self?.statsSummary = snap
                    }
                }

                // Post-session dictionary harvesting. Pure, synchronous,
                // client-side: pull candidate terms that appear both in
                // the final transcript AND in the on-screen context the
                // model saw at session start. `DictionaryHarvester`
                // replaced the old LLM extractor (ADR-016 v2): no API
                // call, no skip-on-short-transcript rule, no LLM
                // hallucination risk. The only gate left is "no room" —
                // if the user has filled all 100 slots with sticky
                // entries, harvesting can't write anything anyway.
                self.harvestDictionaryIfRoom(session: session, transcript: entry.text)
            } catch is CancellationError {
                // User-initiated abort via Escape during `.sending`.
                // `cancelRecording` already cleared state, hid the HUD,
                // and nilled `currentSession`. Nothing else to do —
                // including the sleep assertion, which `cancelRecording`
                // already released on the synchronous Escape path.
                Self.log.info("transcription cancelled by user")
            } catch {
                Self.log.error("session stop failed: \(error.localizedDescription, privacy: .public)")
                guard self.currentSession === session, case .sending = self.recordingState else { return }
                self.currentSession = nil
                self.recordingState = .idle
                self.lockedRecording = false
                self.releaseSleepAssertion()
                self.uninstallSpacebarLockTap()
                self.hud.hideTranscribingHUD()
                self.surfaceError(.sessionFailure(error))
            }
        }
    }

    /// Abort the in-flight session. Called by:
    /// - The X button on the recording HUD (`onCancel` closure)
    /// - The global Escape hotkey while a session is active, including
    ///   during the post-release `.sending` phase (Gemini call + paste)
    ///
    /// Drops the audio, cancels any in-flight Gemini request inside the
    /// session, hides the HUD, and returns to idle. Nothing is pasted,
    /// nothing is written to history. The session's `cancel()` method
    /// installs a synthetic `CancellationError` so a racing `stop()`
    /// path bails cleanly without trying to paste a partial transcript.
    private func cancelRecording() {
        // Stray Escape when idle/error is a harmless no-op (the CGEventTap
        // fires for every keystroke globally, we just filter here).
        switch recordingState {
        case .idle, .error: return
        case .recording, .sending: break
        }
        guard let session = currentSession else { return }
        Self.log.info("session cancelled by user (Esc or close button)")

        currentSession = nil
        pressStartedAt = nil
        awaitingSecondTap = false
        lockedRecording = false
        doubleTapTimeout?.cancel()
        doubleTapTimeout = nil
        recordingState = .idle
        releaseSleepAssertion()
        releaseMusicInterruption()
        uninstallSpacebarLockTap()
        // Both calls are idempotent; we hide whichever HUD is currently
        // up (recording HUD during `.recording`, transcribing HUD during
        // `.sending`).
        hud.hideRecordingHUD()
        hud.hideTranscribingHUD()

        // Fire-and-forget the actor-internal cleanup. Don't await — the
        // user wants the UI gone immediately and the session's resources
        // (audio engine, in-flight Gemini call) will tear down in the
        // background.
        Task { @MainActor in
            await session.cancel()
        }
    }

    // MARK: - Sleep assertion

    /// Acquire a `kIOPMAssertPreventUserIdleSystemSleep` assertion for
    /// the duration of the active recording session, iff the user has
    /// toggled `preventSleepDuringRecording` on. Idempotent — repeated
    /// calls during one session are no-ops because the existing
    /// assertion already covers it.
    ///
    /// Single ownership rule: only `AppState` ever touches
    /// `activeSleepAssertion`. `RecordingSession` does NOT see this
    /// type — keeps the IOKit handle on the @MainActor side and
    /// sidesteps any double-release risk from session value-copies
    /// during partial-recovery flows (architecture invariant 6).
    func acquireSleepAssertionIfNeeded() {
        guard preventSleepDuringRecording else { return }
        guard activeSleepAssertion == nil else { return }
        do {
            activeSleepAssertion = try SleepAssertion(reason: "NoType active recording")
            Self.log.info("sleep assertion acquired")
        } catch {
            Self.log.warning("sleep assertion acquire failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Release the active sleep assertion, if any. Idempotent — safe
    /// to call from every session-end path (success, terminal error,
    /// user cancel) even when no assertion was acquired (because the
    /// user has the toggle off, or assertion creation failed silently).
    /// Recoverable-only chunk failures (markers) MUST NOT call this
    /// — the session is still live.
    func releaseSleepAssertion() {
        guard let assertion = activeSleepAssertion else { return }
        assertion.release()
        activeSleepAssertion = nil
        Self.log.info("sleep assertion released")
    }

    // MARK: - Music interruption

    /// Acquire a music-interruption assertion (Mute or Pause) for
    /// the duration of the active recording session, iff the user
    /// has picked a non-`.none` mode. Idempotent. Same single-
    /// ownership / acquire-after-session-start / release-only-on-
    /// terminal-end pattern as `SleepAssertion` — see that comment
    /// for the broader rationale.
    ///
    /// Snapshots `musicInterruptionMode` at acquisition time so a
    /// mid-session toggle (user opens Settings, flips Mute → None)
    /// doesn't perturb the in-flight session — release still
    /// undoes the mute we engaged.
    func acquireMusicInterruptionIfNeeded() {
        guard musicInterruptionMode != .none else { return }
        guard activeMusicInterruption == nil else { return }
        let controller = MusicInterruption()
        controller.activate(mode: musicInterruptionMode)
        activeMusicInterruption = controller
        Self.log.info("music interruption acquired (\(self.musicInterruptionMode.rawValue, privacy: .public))")
    }

    /// Release the active music-interruption assertion, if any.
    /// Idempotent. Same call-sites as `releaseSleepAssertion`.
    func releaseMusicInterruption() {
        guard let controller = activeMusicInterruption else { return }
        controller.release()
        activeMusicInterruption = nil
        Self.log.info("music interruption released")
    }

    // MARK: - Hold+Space lock (secondary CGEventTap)

    /// Install the secondary `.defaultTap` that consumes Space when
    /// the recording hotkey is held mid-session. No-op when the
    /// recording hotkey IS Space — Hold+Space-on-Space is ambiguous
    /// (the secondary tap would consume the user's own hotkey).
    /// Idempotent — repeated calls during one session are no-ops
    /// because `spacebarLockMonitor` is already set.
    private func installSpacebarLockTapIfNeeded() {
        guard spacebarLockMonitor == nil else { return }
        guard hotkeyBinding.code != "Space" else {
            Self.log.info("hold+space lock disabled — recording hotkey IS Space")
            return
        }
        let predicate: @Sendable () -> Bool = { [enabled = spacebarLockEnabled] in
            enabled.withLock { $0 }
        }
        let monitor = SpacebarLockMonitor(
            shouldLockOnSpace: predicate,
            onLock: { [weak self] in self?.handleSpacebarLockTrigger() }
        )
        if monitor.start() {
            spacebarLockMonitor = monitor
            Self.log.info("hold+space lock tap installed")
        }
    }

    /// Tear down the secondary tap. Called from every session-end
    /// path: finalize success, finalize error, cancel.
    private func uninstallSpacebarLockTap() {
        guard let monitor = spacebarLockMonitor else { return }
        monitor.stop()
        spacebarLockMonitor = nil
        spacebarLockEnabled.withLock { $0 = false }
        Self.log.info("hold+space lock tap uninstalled")
    }

    /// Pure predicate computing whether the Hold+Space lock should
    /// be enabled. Extracted from `updateSpacebarLockEnabled` so
    /// the gate is testable in isolation — the only `.defaultTap`
    /// in the project sits behind this, and a regression silently
    /// breaks Space typing across the OS during recording.
    ///
    /// **Inputs**
    ///   - `isRecording` — session is in `.recording`
    ///   - `pressActive` — recording hotkey is currently held
    ///     (`pressStartedAt != nil`; we keep it set for the hold
    ///     duration)
    ///   - `lockedRecording` — session has promoted to a hands-free
    ///     locked state; no second Space-lock is needed
    ///   - `hotkeyCode` / `cancelCode` — `HotkeyBinding.code` for
    ///     each shortcut
    ///
    /// **`spaceOwnedElsewhere`.** Both `hotkeyCode == "Space"` and
    /// `cancelCode == "Space"` suppress the predicate. Either
    /// configuration would give Space ambiguous meaning at the
    /// `.headInsertEventTap` site (own-hotkey-consumed-by-self,
    /// or simultaneously-cancel-and-lock). In those configurations
    /// Space's other role wins; Hold+Space silently disables.
    ///
    /// Pinned by `SpacebarLockPredicateTests`.
    ///
    /// `nonisolated` so the predicate is callable from any actor —
    /// it's a pure function of its arguments with no AppState state
    /// dependency. The Settings rebind sheet would benefit from
    /// dry-running the predicate as the user types a potential
    /// binding (preview "Hold+Space will/won't be available with
    /// this key"), and the tap thread's `shouldLockOnSpace`
    /// predicate closure could call this directly in a future
    /// refactor.
    nonisolated static func shouldEnableSpacebarLock(
        isRecording: Bool,
        pressActive: Bool,
        lockedRecording: Bool,
        hotkeyCode: String,
        cancelCode: String
    ) -> Bool {
        let spaceOwnedElsewhere = (hotkeyCode == "Space" || cancelCode == "Space")
        return isRecording && pressActive && !lockedRecording && !spaceOwnedElsewhere
    }

    /// Recompute the lock-protected predicate the secondary tap
    /// reads. Called from every state transition that affects any
    /// of the three inputs: press / release of the recording hotkey,
    /// session start / end, lock event. Cheap — one bool write
    /// under an unfair lock. Delegates to the pure
    /// `shouldEnableSpacebarLock` helper above so the predicate
    /// itself is testable without standing up an AppState.
    fileprivate func updateSpacebarLockEnabled() {
        let isRecording: Bool
        if case .recording = recordingState { isRecording = true } else { isRecording = false }
        let value = Self.shouldEnableSpacebarLock(
            isRecording: isRecording,
            pressActive: pressStartedAt != nil,
            lockedRecording: lockedRecording,
            hotkeyCode: hotkeyBinding.code,
            cancelCode: cancelHotkeyBinding.code
        )
        spacebarLockEnabled.withLock { $0 = value }
    }

    /// Main-actor handler fired by the secondary tap when Space is
    /// consumed during a held recording. Mirrors the lock side of
    /// the existing double-tap path: set `lockedRecording = true`,
    /// cancel any pending double-tap timeout, recompute the
    /// predicate so the next Space goes through.
    private func handleSpacebarLockTrigger() {
        // Defensive — the predicate already filtered, but a race
        // between the tap thread reading and the main actor
        // changing state could in theory still let one stale lock
        // request slip through. Re-check.
        guard case .recording = recordingState else { return }
        guard !lockedRecording else { return }
        guard pressStartedAt != nil else { return }
        lockedRecording = true
        awaitingSecondTap = false
        doubleTapTimeout?.cancel()
        doubleTapTimeout = nil
        updateSpacebarLockEnabled()
        Self.log.info("hold+space → locked recording")
    }

    /// Hand the categorizer a closure that bounces back to MainActor and
    /// updates `categoryAssignments` for SwiftUI. Pulled out of `init`
    /// so the `[weak self]` capture isn't nested under another task's
    /// already-weak `self`.
    private func wireAssignmentCallback() async {
        let categorizer = self.appCategorizer
        await categorizer.setOnAssignmentChanged { [weak self] record in
            await MainActor.run {
                self?.applyAssignmentUpdate(record)
            }
        }
    }

    // MARK: - Instructions (user + category prompts + assignments)

    /// Prompt actually shipped in the `Category instruction:` part for
    /// the given category. User overrides win over defaults; `nil`
    /// (i.e. `.uncategorized` and no override) means the section is
    /// omitted from the Gemini request entirely.
    func effectiveCategoryPrompt(for category: AppCategory) -> String? {
        if let override = categoryPromptOverrides[category], !override.isEmpty {
            return override
        }
        return category.defaultPrompt
    }

    /// Update the global user instruction. Optimistic local update +
    /// fire-and-forget persistence — same pattern as `deleteHistoryEntry`.
    func updateUserInstruction(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        userInstruction = trimmed
        Task { [instructionsStore, trimmed] in
            await instructionsStore.updateUserInstruction(trimmed)
        }
    }

    /// Set or clear a category override. Empty / whitespace-only `prompt`
    /// removes the override (UI then renders the default).
    func updateCategoryPrompt(_ category: AppCategory, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            categoryPromptOverrides.removeValue(forKey: category)
        } else {
            categoryPromptOverrides[category] = trimmed
        }
        Task { [instructionsStore, trimmed] in
            await instructionsStore.setCategoryPromptOverride(
                category,
                prompt: trimmed.isEmpty ? nil : trimmed
            )
        }
    }

    /// Drop the override for a category — UI falls back to the default
    /// prompt for that category.
    func resetCategoryPrompt(_ category: AppCategory) {
        categoryPromptOverrides.removeValue(forKey: category)
        Task { [instructionsStore] in
            await instructionsStore.setCategoryPromptOverride(category, prompt: nil)
        }
    }

    /// Manually move an app to a specific category. Source becomes
    /// `.manual` so the categorizer won't overwrite it on next session.
    func moveAppToCategory(bundleID: String, to category: AppCategory) {
        guard !bundleID.isEmpty else { return }
        let record = AppCategoryAssignment(
            bundleID: bundleID,
            category: category,
            confidence: .high,
            classifiedAt: Date(),
            source: .manual
        )
        categoryAssignments[bundleID] = record
        Task { [instructionsStore, bundleID, category] in
            await instructionsStore.setManualAssignment(bundleID: bundleID, category: category)
        }
    }

    /// Remove the cached assignment — next session in this app will
    /// re-trigger classification.
    func removeAssignment(bundleID: String) {
        categoryAssignments.removeValue(forKey: bundleID)
        Task { [instructionsStore, bundleID] in
            await instructionsStore.removeAssignment(bundleID: bundleID)
        }
    }

    /// Force a re-classification of `bundleID`: drop the current
    /// assignment and immediately ask the categorizer to re-run. UI
    /// affordance for the "Re-classify with AI" menu item.
    func refreshAssignment(bundleID: String, displayName: String) {
        guard !bundleID.isEmpty else { return }
        categoryAssignments.removeValue(forKey: bundleID)
        let apiKey = currentAPIKey ?? ""
        Task { [instructionsStore, appCategorizer, bundleID, displayName, apiKey] in
            await instructionsStore.removeAssignment(bundleID: bundleID)
            await appCategorizer.classifyIfNeeded(
                bundleID: bundleID,
                displayName: displayName,
                apiKey: apiKey
            )
        }
    }

    /// Apply a fresh `InstructionsSnapshot` onto the main-actor mirror.
    /// Called at init time and after any future bulk refresh.
    private func applyInstructionsSnapshot(_ snap: InstructionsSnapshot) {
        userInstruction = snap.userInstruction
        categoryPromptOverrides = snap.categoryPromptOverrides
        categoryAssignments = snap.categoryAssignments
    }

    /// Apply a single assignment change handed to us by the categorizer
    /// (background classify, fire-and-forget). Adds or replaces the
    /// row in the in-memory mirror so SwiftUI redraws the Instructions
    /// tab without a full snapshot refresh.
    private func applyAssignmentUpdate(_ record: AppCategoryAssignment) {
        categoryAssignments[record.bundleID] = record
    }

    /// Capture the inputs RecordingSession needs to compute its
    /// per-session category + instruction sections. Read once at the
    /// start of each session and frozen for the session's lifetime so
    /// the cached Gemini prefix stays byte-stable across chunks.
    func currentInstructionsContext() -> InstructionsContext {
        let prompts = categoryPromptOverrides
        let assignments = categoryAssignments
        return InstructionsContext(
            userInstruction: userInstruction,
            promptForCategory: { category in
                if let custom = prompts[category], !custom.isEmpty { return custom }
                return category.defaultPrompt
            },
            cachedCategoryForBundle: { bundleID in
                assignments[bundleID]?.category
            }
        )
    }

    // MARK: - Dictionary

    /// Number of user-source entries in the personal dictionary. Drives
    /// the "no room for harvester" gate (when this equals the cap, all
    /// 100 slots are sticky and harvesting can't write).
    var dictionaryUserEntryCount: Int {
        dictionaryEntries.lazy.filter { $0.source == .user }.count
    }

    /// Post-session client-side dictionary harvest. Reads the session's
    /// captured `ContextSnapshot` (AX tree + OCR + insertion target),
    /// intersects with the just-pasted transcript via
    /// `DictionaryHarvester.harvest`, and writes any new candidates to
    /// the store as `.auto` entries (FIFO-trim handles cap overflow).
    ///
    /// Skipped when the user has filled all 100 slots with sticky `.user`
    /// entries — `DictionaryStore.addAutoEntries` would no-op anyway, and
    /// running the harvest is a small waste of work in that case.
    func harvestDictionaryIfRoom(session: RecordingSession, transcript: String) {
        guard dictionaryEnabled else { return }
        guard dictionaryUserEntryCount < DictionarySnapshot.maxTotalEntries else { return }
        guard !transcript.isEmpty else { return }
        guard let context = session.cachedContext else { return }

        let contextText = Self.assembleContextText(context)
        guard !contextText.isEmpty else { return }

        let existing = dictionaryEntries.map { $0.word }
        let candidates = DictionaryHarvester.harvest(
            transcript: transcript,
            context: contextText,
            existing: existing
        )
        guard !candidates.isEmpty else { return }
        Self.log.info("dictionary harvest: \(candidates.count) candidate(s)")

        Task { [dictionaryStore, candidates] in
            let snap = await dictionaryStore.addAutoEntries(candidates)
            await MainActor.run { [weak self] in
                self?.applyDictionarySnapshot(snap)
            }
        }
    }

    /// Assemble the strings the harvester searches against — AX tree,
    /// optional OCR fallback, and the insertion target's textBefore /
    /// textAfter. Mirrors the body that goes into the `On-screen context:`
    /// and `Insertion target:` Gemini prompt sections, so the harvester
    /// sees the exact same surroundings the transcription model did.
    private static func assembleContextText(_ context: ContextSnapshot) -> String {
        var parts: [String] = []
        let tree = context.tree.formattedForPrompt()
        if !tree.isEmpty { parts.append(tree) }
        if let ocr = context.screenText?.formattedForPrompt(), !ocr.isEmpty {
            parts.append(ocr)
        }
        let target = context.insertionTarget
        if !target.textBefore.isEmpty { parts.append(target.textBefore) }
        if !target.textAfter.isEmpty { parts.append(target.textAfter) }
        return parts.joined(separator: "\n")
    }

    /// Capture the inputs RecordingSession needs to build its
    /// `User dictionary:` cache-prefix section and its replacement
    /// pass. Read once at the start of each session and frozen for the
    /// session's lifetime so the cached Gemini prefix stays byte-stable
    /// across chunks.
    func currentDictionaryContext() -> DictionaryContext {
        let snapshot = DictionarySnapshot(
            entries: dictionaryEntries,
            replacements: dictionaryReplacements
        )
        // When the master toggle is off, ship zero entries so the
        // `User dictionary:` prompt section renders `(empty)`. The
        // replacement pass is intentionally untouched — Auto-replacement
        // is a separate panel and a separate concern.
        let activeEntries = dictionaryEnabled ? snapshot.promptEntries() : []
        return DictionaryContext(
            activeEntries: activeEntries,
            replacements: snapshot.replacements
        )
    }

    /// Flip the master toggle. Persists immediately to UserDefaults so a
    /// crash mid-session doesn't reset the user's choice.
    func setDictionaryEnabled(_ enabled: Bool) {
        guard dictionaryEnabled != enabled else { return }
        dictionaryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.dictionaryEnabledKey)
    }

    /// Two-stage bulk delete. First call wipes every `.auto` entry; once
    /// only `.user` entries remain, a second call wipes those. The UI's
    /// "Clear all" button selects the source based on what's still
    /// present and styles itself destructively on stage 2 so the user
    /// gets a visual hint before nuking their typed terms.
    func clearAutoDictionaryEntries() {
        let removed = dictionaryEntries.filter { $0.source == .auto }
        guard !removed.isEmpty else { return }
        dictionaryEntries.removeAll { $0.source == .auto }
        Task { [dictionaryStore] in
            await dictionaryStore.removeEntries(source: .auto)
        }
    }

    func clearUserDictionaryEntries() {
        let removed = dictionaryEntries.filter { $0.source == .user }
        guard !removed.isEmpty else { return }
        dictionaryEntries.removeAll { $0.source == .user }
        Task { [dictionaryStore] in
            await dictionaryStore.removeEntries(source: .user)
        }
    }

    /// Add a user-typed entry. Trims, caps at `DictionarySnapshot.maxEntryLength`
    /// chars, dedupes case-insensitively (an existing `.auto` row is
    /// promoted to `.user`). Optimistic local update + fire-and-forget
    /// persistence.
    func addUserDictionaryEntry(_ word: String) {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= DictionarySnapshot.maxEntryLength else { return }
        let now = Date()
        let lower = cleaned.lowercased()
        if let idx = dictionaryEntries.firstIndex(where: { $0.word.lowercased() == lower }) {
            let existing = dictionaryEntries[idx]
            dictionaryEntries[idx] = DictionaryEntry(
                id: existing.id,
                word: existing.word,
                source: .user,
                addedAt: now
            )
        } else {
            dictionaryEntries.append(DictionaryEntry(word: cleaned, source: .user, addedAt: now))
        }
        Task { [dictionaryStore, cleaned, now] in
            await dictionaryStore.addUserEntry(cleaned, now: now)
        }
    }

    /// Remove a dictionary entry regardless of source. Used by the chip
    /// X-button in the Dictionary tab.
    func removeDictionaryEntry(id: UUID) {
        dictionaryEntries.removeAll { $0.id == id }
        Task { [dictionaryStore, id] in
            await dictionaryStore.removeEntry(id: id)
        }
    }

    /// Add a replacement pair. Trims both sides, rejects when either is
    /// empty after trim. Duplicate `from` (case-insensitive) replaces
    /// the existing pair's `to` — keeps the apply order deterministic.
    func addReplacement(from: String, to: String) {
        let cleanedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedFrom.isEmpty, !cleanedTo.isEmpty else { return }
        let now = Date()
        let lower = cleanedFrom.lowercased()
        if let idx = dictionaryReplacements.firstIndex(where: { $0.from.lowercased() == lower }) {
            let existing = dictionaryReplacements[idx]
            dictionaryReplacements[idx] = DictionaryReplacement(
                id: existing.id,
                from: cleanedFrom,
                to: cleanedTo,
                createdAt: existing.createdAt
            )
        } else {
            dictionaryReplacements.append(DictionaryReplacement(from: cleanedFrom, to: cleanedTo, createdAt: now))
        }
        Task { [dictionaryStore, cleanedFrom, cleanedTo, now] in
            await dictionaryStore.addReplacement(from: cleanedFrom, to: cleanedTo, now: now)
        }
    }

    /// Update both sides of an existing replacement by id.
    func updateReplacement(id: UUID, from: String, to: String) {
        let cleanedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedFrom.isEmpty, !cleanedTo.isEmpty else { return }
        if let idx = dictionaryReplacements.firstIndex(where: { $0.id == id }) {
            let existing = dictionaryReplacements[idx]
            dictionaryReplacements[idx] = DictionaryReplacement(
                id: existing.id,
                from: cleanedFrom,
                to: cleanedTo,
                createdAt: existing.createdAt
            )
        }
        Task { [dictionaryStore, id, cleanedFrom, cleanedTo] in
            await dictionaryStore.updateReplacement(id: id, from: cleanedFrom, to: cleanedTo)
        }
    }

    func removeReplacement(id: UUID) {
        dictionaryReplacements.removeAll { $0.id == id }
        Task { [dictionaryStore, id] in
            await dictionaryStore.removeReplacement(id: id)
        }
    }

    /// Apply a fresh `DictionarySnapshot` onto the main-actor mirror.
    /// Called at init time and from the extractor's onWordsAdded
    /// callback after it writes new auto entries.
    private func applyDictionarySnapshot(_ snap: DictionarySnapshot) {
        dictionaryEntries = snap.entries
        dictionaryReplacements = snap.replacements
    }

    /// Kick off a background categorize for a bundle we haven't seen
    /// before. Fire-and-forget — does not block the session.
    func classifyAppInBackground(bundleID: String, displayName: String) {
        let apiKey = currentAPIKey ?? ""
        guard !apiKey.isEmpty else { return }
        Task { [appCategorizer, bundleID, displayName, apiKey] in
            await appCategorizer.classifyIfNeeded(
                bundleID: bundleID,
                displayName: displayName,
                apiKey: apiKey
            )
        }
    }

    // MARK: - Error surface

    /// Translates an internal error into a user-facing HUD payload and
    /// shows it. Persistent — the HUD stays until dismissed or replaced.
    private func surfaceError(_ kind: NoTypeErrorKind) {
        let payload = kind.payload
        let onRetry: (@MainActor () -> Void)? = kind.retryHandler.map { handler in
            { @MainActor [weak self] in handler(self) }
        }
        hud.showErrorHUD(payload: payload, onRetry: onRetry)
    }
}

// MARK: - User-facing error catalogue

/// Mapping table from internal error sources to ErrorHUD payloads.
/// Centralising this here keeps strings out of the per-call sites and
/// makes it obvious how each failure mode is surfaced to the user.
///
/// Visibility is `internal` (default) so `NoTypeTests` can pin the
/// catalogue's invariant via `@testable import NoType` — specifically
/// the regression-guard that every `payload.retryLabel != nil` kind
/// also ships a non-`nil` `retryHandler` (see
/// `MissingKeyHUDRetryTests`). Was previously `private`; nobody outside
/// this file references it.
enum NoTypeErrorKind {
    case missingAPIKey
    case vadLoadFailed
    case sessionStartFailed(Error)
    case sessionFailure(Error)
    /// Session finished and pasted, but one or more chunks' Gemini
    /// calls failed recoverably and were replaced with the marker
    /// (`RecordingSession.failureMarker`) in the pasted text. Neutral
    /// severity — this is a heads-up, not a failure, and the user
    /// already has most of their transcription.
    case partialTranscription(summary: RecordingSession.SessionSummary)

    var payload: ErrorPayload {
        switch self {
        case .missingAPIKey:
            return ErrorPayload(
                title: "Add a Gemini API key",
                description: "NoType needs a Gemini API key to transcribe your voice. Open Settings to paste yours.",
                code: "ERR_NO_KEY",
                severity: .warning,
                iconSymbol: "key.fill",
                retryLabel: "Open Settings",
                retryKind: .accent
            )
        case .vadLoadFailed:
            return ErrorPayload(
                title: "Voice detector failed to load",
                description: "NoType couldn't initialise the on-device speech detector. Try restarting the app.",
                code: "ERR_VAD_LOAD",
                severity: .danger,
                iconSymbol: "exclamationmark.triangle.fill"
            )
        case .sessionStartFailed(let err):
            return ErrorPayload(
                title: "Couldn't start recording",
                description: err.localizedDescription,
                code: "ERR_SESSION_START",
                severity: .danger,
                iconSymbol: "mic.slash.fill"
            )
        case .sessionFailure(let err):
            return Self.payloadForSessionFailure(err)
        case .partialTranscription(let summary):
            let failed = summary.failedChunkCount
            let total = summary.dispatchedChunkCount
            let body: String
            if failed == 1 {
                body = "1 of \(total) chunks didn't transcribe — \(RecordingSession.failureMarker) was inserted in its place. Re-dictate just that part if you need it."
            } else {
                body = "\(failed) of \(total) chunks didn't transcribe — \(RecordingSession.failureMarker) was inserted in their place. Re-dictate the missing parts if you need them."
            }
            return ErrorPayload(
                title: "Pasted with gaps",
                description: body,
                code: "INFO_PARTIAL",
                severity: .neutral,
                iconSymbol: "ellipsis.bubble"
            )
        }
    }

    var retryHandler: (@MainActor (AppState?) -> Void)? {
        switch self {
        case .missingAPIKey:
            // The closure type is `@MainActor` — compile-time
            // enforcement that every call site (the
            // `@MainActor () -> Void` wrapper in `surfaceError`, fired
            // from `HUDController.showErrorHUD`'s onRetry → SwiftUI
            // button action) is on the main actor. Previously this
            // body used `MainActor.assumeIsolated`, which is the
            // rejected pattern per
            // `docs/solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`
            // (same `swift_task_isCurrentExecutor*` family that
            // crashed `.onHover` on macOS 26.2).
            return { app in
                guard let app else { return }
                app.pendingTabSelection = .settings
                app.pendingSettingsCategory = .apiUsage
                // Tracks whether we issued a real raise/open so the
                // stale-flag-hijack guard below can run. If we leave
                // the pending flags set without anything happening
                // visibly, a later unrelated window-open trigger
                // (popover gear) silently lands the user on API &
                // Usage instead of General.
                let didRaise: Bool
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue == "main"
                }) {
                    window.makeKeyAndOrderFront(nil)
                    didRaise = true
                } else if let openMainWindow = app.openMainWindowRequest {
                    // `Window` scenes are lazily created and aren't in
                    // NSApp.windows until SwiftUI's openWindow triggers
                    // them — fall through to the injected closure.
                    openMainWindow()
                    didRaise = true
                } else {
                    didRaise = false
                }
                if !didRaise {
                    app.pendingTabSelection = nil
                    app.pendingSettingsCategory = nil
                    return
                }
                // Activate the app so the just-raised window lands in
                // front of whatever the user was previously in (Slack /
                // Notes / ...). Same pattern as `HistoryPopover.openSettings`.
                NSApp.activate(ignoringOtherApps: true)
            }
        default:
            return nil
        }
    }

    /// Translate any error thrown out of `RecordingSession.stop()` into
    /// a user-facing payload. We special-case the network and Gemini
    /// HTTP error codes — they're the most common and most actionable.
    private static func payloadForSessionFailure(_ err: Error) -> ErrorPayload {
        if let urlError = err as? URLError {
            return payloadForURLErrorCode(urlError.code.rawValue, fallbackDescription: urlError.localizedDescription)
        }
        // `GeminiClient.performOnce` wraps unhandled URLErrors as
        // `GeminiError.http(0, "URLError code=N: …")`. Pre-PR-#39
        // sessions threw the wrapped form here and rendered as
        // "Gemini rejected the request (HTTP 0)" — wrong for
        // offline / timeout. The partial-recovery rethrow in
        // `RecordingSession.stop()` makes this path far more common,
        // so peel the code back out and route through the same
        // URLError-class HUDs as the native-URLError branch above.
        if let g = err as? GeminiClient.GeminiError, case let .http(0, body) = g,
           let code = NetworkErrorTranslator.extractURLErrorCode(from: body) {
            return payloadForURLErrorCode(code, fallbackDescription: body)
        }
        if let g = err as? GeminiClient.GeminiError {
            switch g {
            case .missingKey:
                return ErrorPayload(
                    title: "Add a Gemini API key",
                    description: "NoType needs a Gemini API key to transcribe your voice.",
                    code: "ERR_NO_KEY",
                    severity: .warning,
                    iconSymbol: "key.fill"
                )
            case .http(let s, _) where s == 401 || s == 403:
                return ErrorPayload(
                    title: "API key rejected",
                    description: "Gemini didn't accept the key. Check it in Settings or generate a new one in Google AI Studio.",
                    code: "ERR_BAD_KEY · \(s)",
                    severity: .danger,
                    iconSymbol: "key.slash.fill"
                )
            case .http(let s, _) where s == 429:
                return ErrorPayload(
                    title: "Rate limit reached",
                    description: "Gemini throttled the request. Wait a moment and try again.",
                    code: "ERR_RATE_LIMIT · 429",
                    severity: .warning,
                    iconSymbol: "hourglass"
                )
            case .http(let s, _) where s >= 500:
                return ErrorPayload(
                    title: "Gemini is having trouble",
                    description: "The service returned a server error. Wait a moment and try again.",
                    code: "ERR_GEMINI · \(s)",
                    severity: .danger,
                    iconSymbol: "exclamationmark.triangle.fill"
                )
            case .http(_, let body) where GeminiClient.GeminiError.isRegionBlocked(body: body):
                return ErrorPayload(
                    title: "Gemini unavailable in your region",
                    description: "The Gemini API is restricted in your country. Connect through a VPN and try again.",
                    code: "ERR_REGION · 400",
                    severity: .danger,
                    iconSymbol: "exclamationmark.shield.fill"
                )
            case .http(let s, let body):
                let googleMsg = GeminiClient.GeminiError.sanitizedGoogleMessage(body: body)
                let description = googleMsg.map { "HTTP \(s): \($0). Try again, or check Console for details." }
                    ?? "Unexpected response (HTTP \(s)). Try again, or check Console for details."
                return ErrorPayload(
                    title: "Gemini rejected the request",
                    description: description,
                    code: "ERR_GEMINI · \(s)",
                    severity: .danger,
                    iconSymbol: "exclamationmark.triangle.fill"
                )
            case .blocked(let reason):
                return ErrorPayload(
                    title: "Gemini blocked the request",
                    description: reason,
                    code: "ERR_BLOCKED",
                    severity: .warning,
                    iconSymbol: "exclamationmark.shield.fill"
                )
            case .empty:
                return ErrorPayload(
                    title: "Nothing to transcribe",
                    description: "Gemini returned an empty response. Try speaking a bit louder or holding the hotkey longer.",
                    code: "ERR_EMPTY",
                    severity: .neutral,
                    iconSymbol: "waveform.slash"
                )
            case .decoding:
                return ErrorPayload(
                    title: "Couldn't read response",
                    description: "Gemini returned an unexpected format. Try again — if it keeps happening, open an issue on GitHub.",
                    code: "ERR_DECODE",
                    severity: .danger,
                    iconSymbol: "exclamationmark.triangle.fill"
                )
            }
        }
        if let s = err as? RecordingSession.SessionError, case .noSpeech = s {
            return ErrorPayload(
                title: "No speech detected",
                description: "NoType didn't pick up any voice — try holding ⌥ a moment longer next time.",
                severity: .neutral,
                iconSymbol: "mic.slash"
            )
        }
        return ErrorPayload(
            title: "Transcription failed",
            description: err.localizedDescription,
            code: "ERR_UNKNOWN",
            severity: .danger,
            iconSymbol: "exclamationmark.triangle.fill"
        )
    }

    /// Build the right network-class HUD payload for a raw URLError
    /// code value. Shared between the native-`URLError` branch and the
    /// `GeminiError.http(0, "URLError code=N: …")` re-extraction
    /// branch so both paths render the same offline / timeout HUDs.
    private static func payloadForURLErrorCode(_ rawCode: Int, fallbackDescription: String) -> ErrorPayload {
        let code = URLError.Code(rawValue: rawCode)
        switch code {
        case .notConnectedToInternet, .networkConnectionLost:
            return ErrorPayload(
                title: "No internet connection",
                description: "NoType needs internet to transcribe. Reconnect and try again — your audio wasn't saved.",
                code: "ERR_OFFLINE",
                severity: .danger,
                iconSymbol: "wifi.slash"
            )
        case .timedOut:
            return ErrorPayload(
                title: "Couldn't reach Gemini",
                description: "The transcription request timed out. Check your connection and try again.",
                code: "ERR_NET_TIMEOUT",
                severity: .danger,
                iconSymbol: "exclamationmark.triangle.fill"
            )
        default:
            return ErrorPayload(
                title: "Network error",
                description: fallbackDescription,
                code: "ERR_NET_\(rawCode)",
                severity: .danger,
                iconSymbol: "wifi.exclamationmark"
            )
        }
    }

}

/// Pull the URLError code out of a `GeminiError.http(0, body)`
/// body string of the form `"URLError code=-1009: not connected"`.
/// Returns `nil` when the body isn't a wrapped URLError. Internal so
/// `AppStateNetworkErrorRoutingTests` can pin the parser against
/// `GeminiClient.performOnce`'s wrapping format — drift between the
/// two would silently re-break the offline / timeout HUD routing.
enum NetworkErrorTranslator {
    static func extractURLErrorCode(from body: String) -> Int? {
        let prefix = "URLError code="
        guard body.hasPrefix(prefix) else { return nil }
        let rest = body.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else {
            return Int(rest.trimmingCharacters(in: .whitespaces))
        }
        return Int(rest[..<colon].trimmingCharacters(in: .whitespaces))
    }
}
