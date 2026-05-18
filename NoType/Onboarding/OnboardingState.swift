import Foundation
import Observation
import SwiftUI

/// Drives the first-run wizard. Owns the current step, the highest step
/// the user has ever reached (so reopening the window resumes mid-flow),
/// and a persisted "completed" flag that retires the wizard for good.
///
/// Lives alongside `AppearanceController` in `NoTypeApp` and is injected
/// into both `AppState` (so it can suppress permission HUDs while the
/// wizard is up) and `MainWindowView` (so it can swap the body for the
/// wizard).
@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable, Sendable {
        case welcome      = 0
        case apiKey       = 1
        case permissions  = 2
        case micCheck     = 3
        case hotkeyCheck  = 4
        case complete     = 5
    }

    nonisolated static let currentStepKey  = "notype.onboarding.currentStep"
    nonisolated static let furthestStepKey = "notype.onboarding.furthestStep"
    nonisolated static let completeKey     = "notype.onboarding.complete"

    /// Synchronous read of the persisted "wizard already finished" flag,
    /// callable from outside the actor (e.g. `NoTypeApp` scene-graph
    /// build, where we need to decide tray-icon insertion + window
    /// launch behaviour before the `@State` value is available).
    nonisolated static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: completeKey)
    }

    private(set) var currentStep:  Step
    private(set) var furthestStep: Step

    /// Backing `UserDefaults` for read / write of the three onboarding
    /// keys. Defaults to `.standard` in production. Injectable so unit
    /// tests can use an isolated suite — otherwise `goNext()` and
    /// `resetWizard()` would poison the host process's standard
    /// defaults (this test bundle is application-hosted in `NoType.app`,
    /// so `UserDefaults.standard` inside a test = `app.notype` on disk).
    private let defaults: UserDefaults

    var isComplete:   Bool { currentStep == .complete }
    var isOnboarding: Bool { !isComplete }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.bool(forKey: Self.completeKey) {
            self.currentStep  = .complete
            self.furthestStep = .complete
            return
        }
        let curr = defaults.object(forKey: Self.currentStepKey) as? Int
        let furt = defaults.object(forKey: Self.furthestStepKey) as? Int
        self.currentStep  = Step(rawValue: curr ?? 0) ?? .welcome
        self.furthestStep = Step(rawValue: max(curr ?? 0, furt ?? 0)) ?? .welcome
    }

    /// Move forward one step and persist. Bumps `furthestStep` if needed.
    /// Hitting `.complete` writes the terminal flag — subsequent launches
    /// skip the wizard entirely.
    func goNext() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        if next.rawValue > furthestStep.rawValue {
            furthestStep = next
        }
        if next == .complete {
            defaults.set(true, forKey: Self.completeKey)
        }
        persist()
    }

    /// Move back one step. Welcome is the floor — there's no step before it.
    /// `furthestStep` is preserved so the user can navigate forward without
    /// re-validating things they already completed.
    func goBack() {
        guard currentStep != .welcome else { return }
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
        persist()
    }

    private func persist() {
        defaults.set(currentStep.rawValue,  forKey: Self.currentStepKey)
        defaults.set(furthestStep.rawValue, forKey: Self.furthestStepKey)
    }

    /// Reopen the onboarding wizard from `welcome` without losing the
    /// user's saved API key, hotkey binding, or selected microphone.
    ///
    /// Called by the Settings → General → "Reset onboarding" button
    /// (plan §305, AE9). Only the three onboarding UserDefaults keys
    /// are cleared. The wizard's API-key step detects the existing
    /// Keychain entry and skips revalidation when the pre-filled value
    /// is unchanged — see `OnboardingAPIKeyStep.continueTapped`'s
    /// "Resume path" branch. That keeps a user with a known-good key
    /// from being trapped on the API-key step.
    func resetWizard() {
        Self.resetWizardDefaults(in: defaults)
        currentStep  = .welcome
        furthestStep = .welcome
    }

    /// Side-effect-only counterpart of `resetWizard()` — clears the
    /// three onboarding keys in any `UserDefaults` instance. Exposed
    /// so tests can verify on an isolated suite without touching the
    /// process-wide standard defaults.
    nonisolated static func resetWizardDefaults(in defaults: UserDefaults) {
        defaults.removeObject(forKey: currentStepKey)
        defaults.removeObject(forKey: furthestStepKey)
        defaults.removeObject(forKey: completeKey)
    }
}
