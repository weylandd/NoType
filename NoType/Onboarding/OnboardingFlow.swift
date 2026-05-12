import SwiftUI

/// Root view of the onboarding wizard. Switches on
/// `OnboardingState.currentStep` and renders the matching step. Owns no
/// state of its own — `OnboardingState` is the single source of truth
/// for which step is showing.
///
/// Mounted by `MainWindowView` whenever `onboarding.isComplete == false`
/// in place of the normal sidebar + HomeView layout.
struct OnboardingFlow: View {
    @Environment(OnboardingState.self) private var onboarding

    var body: some View {
        switch onboarding.currentStep {
        case .welcome:
            OnboardingWelcomeStep()
        case .apiKey:
            OnboardingAPIKeyStep()
        case .permissions:
            OnboardingPermissionsStep()
        case .micCheck:
            OnboardingMicCheckStep()
        case .hotkeyCheck:
            OnboardingHotkeyStep()
        case .complete:
            // Defensive — `MainWindowView` swaps to HomeView before this
            // can render, but if it ever does we don't want to crash.
            Color.clear
        }
    }
}
