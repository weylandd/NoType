# Permissions

NoType needs two macOS permissions to function plus one optional permission that turns on a fallback context source. All three are presented in the onboarding wizard; status is surfaced afterward via the menu-bar icon dot and the floating permission-card HUDs (the optional one never blocks).

| Permission | Why | Required? | Request API | Settings pane |
|---|---|---|---|---|
| **Microphone** | Audio capture | Required | `AVCaptureDevice.requestAccess(for: .audio)` | Privacy & Security → Microphone |
| **Accessibility** | (1) `CGEventTap` for the global hotkey, (2) reading the AX tree of all on-screen windows | Required | `AXIsProcessTrustedWithOptions` (with `AXTrustedCheckOptionPrompt = true`) | Privacy & Security → Accessibility |
| **Screen Recording** | Active-window screenshot + Vision OCR fallback for apps where AX returns nothing (Electron, web-views, custom NSText). See ADR-014. | **Optional** | `CGRequestScreenCaptureAccess()` (wrapped by `ScreenRecordingPermission.request()`) | Privacy & Security → Screen Recording |

The Screen Recording card is rendered with an explicit "Optional" pill in onboarding and a neutral chip (not warning) when ungranted. The wizard's "Continue" button gates only on Microphone + Accessibility — skipping Screen Recording is fully supported and the user can grant later via System Settings; `PermissionsViewModel` polls and the fallback turns on without restart. Screen Recording is **deliberately not** part of `PermissionsViewModel.allGranted` / `.recordingReady`.

We deliberately do **not** request:
- **Speech Recognition** — we use Silero (CoreML) for VAD, not Apple's speech stack. `AVAudioEngine` does not trigger the TCC prompt for this on the supported macOS versions (14+) with our current entitlements; the key is not in `Info.plist`.
- **Apple Events** — we don't script other apps.
- **Full Disk Access** — we only read/write our own Application Support folder.

---

## Info.plist keys

```xml
<key>NSMicrophoneUsageDescription</key>
<string>NoType uses the microphone to record your voice for dictation.</string>

<key>NSAccessibilityUsageDescription</key>
<string>NoType reads on-screen text to improve transcription accuracy.</string>

<key>NSScreenCaptureUsageDescription</key>
<string>NoType reads on-screen text via screenshots to improve dictation accuracy in apps that don't expose their content via the accessibility API. Screen capture is optional — leave it off to use accessibility-only context.</string>

<key>LSUIElement</key>
<true/>

<key>NSSupportsAutomaticTermination</key>
<false/>
<key>NSSupportsSuddenTermination</key>
<false/>
```

`LSUIElement = true` makes NoType an accessory app: no Dock icon, no main menu bar (we add the `MenuBarExtra` programmatically). The `NSSupports*Termination = false` pair keeps the process alive when no windows are visible — without them AppKit would silently terminate the LSUIElement app it considers idle, taking the menu-bar tray, hotkey monitor, and in-flight recording session with it.

---

## Onboarding flow

On first launch (no API key on file) the main window opens directly into the wizard (`NoType/Onboarding/`). Steps:

1. **Welcome.** One sentence: "Hold Right Option and talk. NoType transcribes and pastes."
2. **API key.** Input field for Gemini key + a link to Google AI Studio with instructions to create one. "Continue" calls `GeminiClient.validateKey(_:)` — a no-cost `GET /v1beta/models` with the key in the `x-goog-api-key` header — that returns 200 for any valid key and 401/403 for a bad one, before persisting via `SecretStore`. If a key already exists it shows `AIzaSy••••••••` with an Edit link; editing forces revalidation.
3. **Permissions.** Cards for Microphone, Accessibility, and Screen Recording (Optional). Each shows status and a "Grant" button that calls the request API; if the user has previously denied, it opens the relevant Settings pane via `x-apple.systempreferences:` URL. The Screen Recording card uses an explicit "Optional" pill and a neutral (not warning) chip — its state never gates the wizard's Continue button.
4. **Mic check.** Uses `MicProbe` (`NoType/Onboarding/MicProbe.swift`) — its own `AVAudioEngine` instance, no VAD, no `RecordingSession` — to render a live spectrum so the user can confirm the right input device is being captured.
5. **Hotkey check.** Holds the hotkey to confirm CGEventTap fires; `AppState.onboardingHotkeyPressObserver` short-circuits the press so it flips a keycap visual instead of starting a real session.

`OnboardingState` (persisted to `UserDefaults` under `notype.onboarding.{currentStep,furthestStep,complete}`) is the single source of truth. The wizard can be re-opened later from Settings.

While the wizard is pending, both the menu-bar `MenuBarExtra` and the global permission-card HUDs are suppressed — onboarding owns the prompting flow until completion.

---

## Status surfacing after onboarding

When permissions are missing or the key is invalid after onboarding completes, NoType surfaces them three ways:

- **Menu-bar icon dot.** Yellow for warning, red for broken state.
- **Permission-card HUDs.** Stacked top-right at app launch, when the user clicks the menu-bar icon with permissions missing, or (microphone-only) when they press the hotkey without microphone access. Cards are explicit-show-only — they never re-appear automatically after the user dismisses them; the next trigger re-shows.
- **Error HUD.** When a hotkey press is blocked by missing API key or VAD load failure, `AppState.surfaceError(_:)` runs an `ErrorPayload` through `HUDController.showErrorHUD(...)`.

---

## Sandboxing

NoType is **not** sandboxed. We distribute outside the Mac App Store (see ADR-012). Sandboxing complicates `CGEventTap` and Accessibility tree access enough that for v1 we ship without it. Hardened runtime is enabled (`ENABLE_HARDENED_RUNTIME: YES` in `project.yml`) and notarization is required for direct distribution — see `docs/build.md`.
