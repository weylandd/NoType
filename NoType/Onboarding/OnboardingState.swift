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

    var isComplete:   Bool { currentStep == .complete }
    var isOnboarding: Bool { !isComplete }

    init() {
        if UserDefaults.standard.bool(forKey: Self.completeKey) {
            self.currentStep  = .complete
            self.furthestStep = .complete
            return
        }
        let curr = UserDefaults.standard.object(forKey: Self.currentStepKey) as? Int
        let furt = UserDefaults.standard.object(forKey: Self.furthestStepKey) as? Int
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
            UserDefaults.standard.set(true, forKey: Self.completeKey)
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
        UserDefaults.standard.set(currentStep.rawValue,  forKey: Self.currentStepKey)
        UserDefaults.standard.set(furthestStep.rawValue, forKey: Self.furthestStepKey)
    }
}
