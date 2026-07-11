# Changelog

All notable changes to NoType are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Until v1.0.0, breaking changes may land on minor (`0.x`) bumps.

---

## [Unreleased]

---

## [0.1.11] — 2026-07-11

### Added
- **Screen-capture context toggle** (#71). Settings → Recording now has a
  "Use screen capture for context" switch that turns the OCR/screenshot
  fallback off independently of the Screen Recording permission — so you
  can keep the permission granted but stop NoType from screenshotting.
  Default on; when the permission isn't granted the switch routes you to
  System Settings.

### Fixed
- **Gemini API key no longer "disappears"** (#70). The key now lives in
  the data-protection keychain, scoped by an access group instead of the
  rotating code-signing identity. Reading it survives re-signing and dev
  certificate rotation and never pops the login-password prompt. Existing
  keys migrate automatically on first launch; anyone already stranded by
  the old bug gets a calm one-time "re-enter your key" note.
- **Replacements now fire on punctuation-edged pairs** (#77). Auto-
  replacement pairs whose `from` starts or ends with punctuation
  (`e.g.`, `.com`, `c#`, `#tag`, `т.е.`) are now matched and applied —
  previously the word-boundary rule silently skipped them.
- **Final words of a quick multi-phrase dictation no longer dropped**
  (#77). Releasing the hotkey right after a fast burst of phrases could
  occasionally lose the last phrase's text; it's now retained.
- **Cancelling a finishing transcription leaves nothing behind** (#77).
  Pressing the cancel key while a transcription is wrapping up no longer
  pastes or saves a stray transcript.
- **Revoking Accessibility mid-recording releases the mic** (#77).
  Turning off the Accessibility permission during a recording now ends
  the session and stops capture instead of leaving the microphone live.
- **Your clipboard is left alone during the paste restore delay** (#77).
  If you copy something while NoType is restoring your clipboard after a
  paste, your copy is no longer overwritten.
- **Onboarding no longer jumps forward after you go Back** (#77). When
  API-key validation finishes after you've navigated to an earlier step,
  the wizard now stays where you are instead of skipping ahead.
- **No surprise Screen Recording prompt when capture context is off**
  (#77). With the screen-capture context toggle off, the first push-to-
  talk press no longer interrupts you with a Screen Recording prompt.
- **Blocked or cut-short transcriptions surface a clear message** (#77).
  A transcription the model blocks or truncates now shows a readable
  message and a gap marker instead of a silent or garbled result.

### Changed
- **New app icon** (#69).
- **Honest onboarding privacy wording** (#77). The onboarding privacy
  copy now accurately describes how dictation works: your audio and API
  key go to Google's Gemini for transcription, and nothing is sent to us.
- Audio compression moved off the main thread; assorted robustness fixes
  and dead-code cleanup (#77).

### Security
- **Wider redaction of secrets in the on-screen context** (#77). The
  context sent for transcription now scrubs more: window and element
  titles, secrets straddling the text cursor, and standard-base64
  tokens — and the focused-field skip rules match the full accessibility
  walker.

---

## [0.1.10] — 2026-05-29

### Added
- **Switchable transcription model** (#65). Settings → API & Usage now
  lets you choose between Gemini 3.1 Flash-Lite (default) and 3.5 Flash
  for transcription; usage cost is tracked per-model so historical
  spend stays priced correctly. The classifier stays on Flash-Lite
  regardless of the transcription choice.
- **Length-disproportionate hallucination gate** (#63). Drops Gemini
  transcripts whose word and char rate both exceed plausible dictation
  speed for the audio duration — catches Flash-Lite's conversational
  fallback hallucinations on short, low-information audio (e.g. a
  Bluetooth-HFP mic).

### Fixed
- **Music no longer stays muted after recording ends** (#64). Removed
  the `.pause` toggle; the mute is lifted at recording-end.
- **Region-block errors explain themselves** (#60). A Gemini regional
  block now surfaces a readable explanation instead of a bare
  "Gemini error 400".
- **"Open Settings" button on the missing-API-key HUD now works** (#59).
  It was previously wired to nothing.

### Changed
- Bumped `softprops/action-gh-release` 2 → 3 (#62) and
  `apple-actions/import-codesign-certs` 3 → 7 (#61) in CI.

---

## [0.1.9] — 2026-05-19

Hotfix release. One bug fix.

### Fixed
- **SwiftUI `.onHover` no longer crashes the app on macOS 26.2** (#57).
  Third instance of the macOS 26 Swift concurrency executor-check
  family (after `TimelineView` in PR #41 and Core Audio HAL IOProc in
  PR #53 / cd36c48). On macOS 26.2 the closure prologue's
  `swift_task_isCurrentExecutorWithFlagsImpl` check faulted at
  `swift_getObjectType(0x1)`, reading an invalid `SerialExecutorRef`
  identity that SwiftUI's `HoverResponder.updatePhase` handed the
  runtime via `.onHover` closures that inherited `@MainActor` from
  their enclosing View body (per SE-0420). Symptom: instant
  `EXC_BAD_ACCESS` on first cursor movement over almost any
  hover-tracked surface in the main window.

  Fix introduces a `dsOnHover` wrapper in `NoType/UI/DSComponents.swift`
  that pairs `@Sendable` (strips the inherited `@MainActor` so the
  broken closure-prologue check is omitted) with a
  `Task { @MainActor in ... }` bridge (schedules the `@State` write
  through the task scheduler — different code path from the broken
  closure-prologue check; ~one-frame latency, imperceptible for hover
  state). All 28 raw `.onHover` callsites converted to `.dsOnHover`.

  A new `NoTypeTests/DSComponentsHoverTests` pins the convention via
  a `FileManager` walk that fails any new raw `.onHover` outside the
  wrapper definition — closes the lint gap that let this family
  escape twice already.

  Solutions doc: `docs/solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`.
  Cross-references extended across the two prior family docs
  (`timelineview-...`, `audio-ioproc-...`) and the swift-6 concurrency
  convention. `NoType/UI/CLAUDE.md` hard rule added next to the
  existing TimelineView rule.

---

## [0.1.8] — 2026-05-19

Surface-redesign release. Settings, Instructions, Home stats, and now
the Dictionary tab all moved to the new card-based design language;
the app icon and menu-bar glyph picked up the new waveform mark along
the way. One bug fix in the permissions surface.

### Changed
- **Dictionary tab redesigned** (#56) to match the new design
  handoff. Two section blocks (Auto-replacement, Dictionary) each
  carry a mono section header, a scope pill (`Local only` vs
  `Sent to Gemini`), and a `bg-surface` card grouping rows + add
  row + footer. Replacement rows show `from` as a left-aligned
  monospace pill → centered arrow → `to`; the trash slot shares a
  fixed trailing-gutter width with the Add button below so both
  arrow columns line up. The dictionary card gains a `12/100`
  count (warning-coloured at ≥80), an inline `Use dictionary`
  toggle in the head, an embedded character counter in the
  add-entry field, a warn banner when the manual cap is reached,
  a chip cloud with user / auto-harvested variants, and a footer
  with a status dot + two-stage Clear button.
- **Settings and Instructions tabs redesigned** (#52, #53) as a
  two-column shell — a secondary sidebar drives a 5-pane switch
  (General / Recording / Language & Paste / API & Usage / About)
  inside a `ScrollView` with a sticky header. Each pane composes
  one or more `DSCard` sections from a new `DSCard` + `DSCardRow`
  primitive family in `DSComponents.swift`.
- **App icon and menu-bar glyph refreshed** to the new waveform
  mark (#54) — both the rounded-square Dock / About icon and the
  monochrome menu-bar template image were redrawn from the same
  source asset.
- **Home tab: dictation time appears under the Words transcribed
  card** (#55), surfacing the total measured speaking time per the
  current `HomeRange` window. Driven by the new
  `StatsSnapshot.totalDurationSeconds` field already populated by
  `StatsStore`.

### Fixed
- **Accessibility permission surfaces a neutral `.notDetermined`
  state on first launch instead of red `DENIED`** (#51). On a
  fresh install the system API returns `false` for both "never
  asked" and "explicitly denied"; we now emulate `.notDetermined`
  via a `notype.permissions.accessibility.hasAsked` UserDefaults
  flag (same shape as the existing Screen Recording flag), so the
  onboarding row reads `REQUIRED` until the user actually clicks
  Grant. Includes a one-time backfill so users who completed
  onboarding under an older build keep the correct
  `DENIED + Open Settings` surface when they had refused.
- **macOS 26 audio crash on first hotkey press** addressed in #53
  (audio-engine init re-ordering — see the PR for details).

---

## [0.1.7] — 2026-05-17

UI polish release. One user-visible change.

### Changed
- **Main app window is now a fixed 1080×760 size** (#44). Home,
  Instructions, and Dictionary tabs (plus the first-launch onboarding
  wizard) live in a rarely-opened utility shell that didn't benefit
  from a responsive layout. Locking the canvas simplifies the design
  pass and removes a class of resize-related visual quirks. The lock
  combines SwiftUI's `.windowResizability(.contentSize)` + explicit
  min==max frame with an AppKit `NSViewRepresentable` that strips
  `.resizable` from the underlying `NSWindow.styleMask` and pins
  `min/maxSize` — the SwiftUI-only path proved unreliable on macOS 15
  and 26 across Mission Control and display-reconfiguration events.

---

## [0.1.6] — 2026-05-16

Crash + reliability release. Four user-visible fixes targeting paths
that were either crashing on macOS 26 (Tahoe) or producing wrong
behaviour in normal use. The crash report that drove #41 was reliable
on Tahoe within ~3 s of opening the onboarding mic-check step — every
Tahoe tester ran into it. Existing 0.1.5 installs get this update
through Sparkle (≤24 h auto-check or immediately on next main-window
open).

### Fixed
- **Onboarding mic-check no longer crashes on macOS 26 (Tahoe)** (#41).
  `SwiftUI.TimelineView` content closures crashed inside
  `swift_task_isCurrentExecutorWithFlagsImpl` → `objc_opt_class`
  during layout whenever they called a `@MainActor`-isolated View
  instance method on each tick. The onboarding mic-check and the
  recording HUD's live spectrum meter both shipped with that pattern.
  Both now use a `.task { while !Task.isCancelled { … try? await
  Task.sleep(...) } }` driver loop that mutates `@State` directly,
  side-stepping the TimelineView dispatch path entirely. macOS 15
  (Sequoia) wasn't affected by the same binary. The two spectrum
  meters now share a single `SpectrumMeter` view so the broken pattern
  can't reappear in only one of them. Full diagnosis in
  `docs/solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md`.
- **Bluetooth headsets no longer drop to call-quality audio during
  dictation** (#40). macOS would silently switch a connected
  Bluetooth headset out of A2DP and into HFP/SCO whenever NoType
  opened an `AVAudioEngine` input tap — music playing through the
  same headset would drop to phone-call audio for the duration of a
  recording. NoType now prefers the built-in mic when both a
  Bluetooth output and the built-in input are available; the user
  can still pick the Bluetooth mic explicitly via the input picker
  if they want it for dictation.
- **Gemini failures no longer drop the whole session** (#39). A
  single chunk's network blip, 5xx, or decoding error used to
  poison the entire transcript with `.noSpeech` — the user lost
  audio they actually spoke. Each chunk's success now stands alone:
  failures render as `[…]` markers in the stitched transcript, the
  user sees the rest of what they said, and a neutral "Pasted with
  gaps" HUD reports how many chunks fell out. Batched calls that
  hit a recoverable error are split into N independent retries
  before being marked as gaps. Terminal errors (auth, blocked,
  encode, cancellation) still abort the session as before. See
  `docs/solutions/architecture-patterns/partial-recovery-with-markers-2026-05-16.md`.
- **Final-chunk audio no longer silently dropped at end of
  recording** (#38). After hotkey release, the final-chunk audio
  could land in `pending` after `stop()`'s sender drain had already
  returned — the user got `.noSpeech` despite clearly speaking. The
  drain now loops on `senderTask` re-reads
  (`while let task = senderTask { await task.value }`) so every
  respawn is observed. Same PR also tightened the adaptive pause
  threshold ladder so long monologues cut into chunks Gemini can
  actually transcribe inside its 30 s resource timeout (steps down
  to 500 ms at 40 s+ audio), reset Silero VAD state deterministically
  per session instead of relying on warm-up samples, and added
  per-stage lag logging so a future regression in the chunk pipeline
  is diagnosable from production logs.

---

## [0.1.5] — 2026-05-15

Single-fix release. v0.1.4 fresh installs on every supported macOS
launched into an invisible process — no menu-bar icon (suppressed
during onboarding by design), no main window (SwiftUI `Window` is
lazy without `Scene.defaultLaunchBehavior`). Reported on macOS
Sequoia 15.0; reproduced via `lsappinfo info -only windows
app.notype` returning `[ NULL ]` while the process kept running.

### Fixed
- **Onboarding window auto-opens on first launch again** (#17).
  PR #7 dropped the floor to macOS 14 and in the same commit
  removed `Scene.defaultLaunchBehavior(_:)` from `NoTypeApp.swift`
  on the false premise that `MenuBarIcon`'s `.task` was a fallback.
  No such `.task` existed (and the `MenuBarExtra` is gated suppressed
  during onboarding anyway), so every fresh install since the PR #7
  merge surfaced zero UI on first launch. Modifier restored.

### Changed
- **Minimum macOS bumped to 15 (Sequoia)** (#17). The fix above
  requires `Scene.defaultLaunchBehavior(_:)`, which is macOS 15+
  only. `@SceneBuilder` doesn't support `if #available`, so the
  modifier can't be conditionally applied — the floor moves up.
  ADR-001 rewritten with the new floor + a history paragraph
  documenting why PR #7's audit was wrong so it doesn't happen
  again. Sonoma users will stay on 0.1.4 (which is broken there
  too — same regression as everywhere else).

---

## [0.1.4] — 2026-05-14

First release of the macOS 14+ era. NoType now installs and runs
on Sonoma, Sequoia, and Tahoe — the previous macOS 26 floor was a
policy choice that overstated the actual technical requirement.
Release pipeline runs on GitHub Actions instead of a single Mac.
Auto-update banner has a fresh look, and the website's download
link now stays valid across versions without per-release edits.

### Added
- **Lowered minimum macOS to 14 (Sonoma)** (#7). A full audit of
  every native Apple API the project uses confirmed nothing
  required the previous macOS 26 floor — it was a policy choice
  that overstated the real technical floor. ScreenCaptureKit-OCR
  + `@Observable`-driven state set the actual floor at 14.0.
  NoType now installs on 14 / 15 / 26. See ADR-001 for details.
- **Stable "always latest" DMG download link** (#5) — the README's
  download link now points at a redirector that always serves the
  most recent published `.dmg`, so external references don't need
  per-release renumbering.

### Changed
- **Update banner redesign** (#5) — pill placement, motion, and
  download/install copy reworked to match the rest of the
  sidebar's visual language.
- **Release pipeline now runs on GitHub Actions** (#9). Tag a
  commit with `vX.Y.Z` and push — the workflow handles xcodegen,
  archive, notarisation, DMG/.zip assembly, Sparkle EdDSA
  signing, appcast patching, and GitHub Release publication.
  The local `./scripts/release.sh` + `./scripts/publish_release.sh`
  recipe is preserved as the documented fallback.

### Fixed
- **CI Build & Test workflow** (#8). Was failing on a missing
  code signing certificate (the runner doesn't have one, and the
  build doesn't need it for compile/test verification). Now
  passes `CODE_SIGNING_ALLOWED=NO` so the job completes its
  actual purpose. Affects PR-on-PR checks only — release.yml
  still does real signing via the imported cert.
- **Release archive step on CI** (#11, #12). Switched the
  `xcodebuild archive` invocation to Manual signing with
  `Developer ID Application` pinned explicitly; the previous
  Automatic-signing path looked for "Apple Development" cert
  which isn't on the runner. \`ExportOptions.plist\` is synced
  to manual signing as well.
- **Sparkle appcast generation** for the new minimum macOS.
  `sparkle_appcast_item.sh` was hardcoding `<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>`
  per item, which would have hidden v0.1.4 from users on
  Sonoma / Sequoia even though the build supports them. Now
  defaults to 14.0 and accepts `--minimum-system-version` to
  override. Also extracts only the current version's section
  from CHANGELOG.md instead of inlining the whole file.

---

## [0.1.4-rc1] — 2026-05-14

Validation release for the re-enabled CI pipeline. Functionally a
preview of 0.1.4 — the goal of this RC is to confirm that the
GitHub Actions release workflow (re-enabled in #9) successfully
runs end-to-end on the macos-latest runner: build → notarize →
DMG/.zip → Sparkle EdDSA sign → appcast patch → GitHub Release.
The actual 0.1.4 cut follows once this RC validates the path.

### Added
- **Lowered minimum macOS to 14 (Sonoma)** (#7). A full audit of
  every native Apple API the project uses confirmed nothing
  required the previous macOS 26 floor — it was a policy choice
  that overstated the real technical floor. ScreenCaptureKit-OCR
  + `@Observable`-driven state set the actual floor at 14.0.
  NoType now installs on 14 / 15 / 26. See ADR-001 for details.
- **Stable "always latest" DMG download link** (#5) — the README's
  download link now points at a redirector that always serves the
  most recent published `.dmg`, so external references don't need
  per-release renumbering.

### Changed
- **Update banner redesign** (#5) — pill placement, motion, and
  download/install copy reworked to match the rest of the
  sidebar's visual language.
- **Release pipeline now runs on GitHub Actions** (#9). Tag a
  commit with `vX.Y.Z` and push — the workflow handles xcodegen,
  archive, notarisation, DMG/.zip assembly, Sparkle EdDSA
  signing, appcast patching, and GitHub Release publication.
  The local `./scripts/release.sh` + `./scripts/publish_release.sh`
  recipe is preserved as the documented fallback.

### Fixed
- **CI Build & Test workflow** (#8). Was failing on a missing
  code signing certificate (the runner doesn't have one, and the
  build doesn't need it for compile/test verification). Now
  passes `CODE_SIGNING_ALLOWED=NO` so the job completes its
  actual purpose. Affects PR-on-PR checks only — release.yml
  still does real signing via the imported cert.

---

## [0.1.3] — 2026-05-14

First non-RC release through the Sparkle auto-update pipeline.
Adds a master toggle and bulk-clear affordance to the Dictionary
tab, and overhauls the auto-harvest algorithm to eliminate the
chrome-word and case-promotion noise that polluted earlier
sessions. Plus a paste-time boundary fix from `fix/insertion-
leading-space-and-prompt-audit`.

### Added
- **Dictionary master toggle** — accent-tinted switch in the
  Dictionary panel header. When off, the `User dictionary:` Gemini
  prompt section ships `(empty)` (cache shape preserved) and
  post-session auto-harvest is skipped. Panel body dims to 45 %
  but stays editable. Replacement-pairs panel is intentionally
  unaffected.
- **Two-stage Clear-all** in the Dictionary panel header (visible
  only when the dictionary is non-empty). First click wipes
  `.auto` entries with neutral styling. Once only `.user` remains,
  the button flips to a destructive tint (`dangerFg` + `dangerSoft`
  hover fill) before wiping user-typed entries.
- **NLLanguageRecognizer-based noun-cap-language detection**
  (German today). Disables the first-cap tier on the auto-harvest
  so German common nouns (`Haus`, `Auto`, `Termin`) don't surface
  as dictionary entries. Extensible via
  `DictionaryHarvester.nounCapitalizingLanguages`.

### Changed
- **Auto-harvest is now transcript-driven.** Triggers are detected
  on transcript tokens, not on canonical pulled from context. The
  earlier behaviour promoted lowercase transcript words (`минуты`,
  `packages`) to capitalized canonicals when context showed them
  capitalized — that case-promotion path is gone.
- **Phrase candidate generation** uses a ±2 word window per
  trigger within the same sentence (detected via
  `NLTokenizer(.sentence)`). Boundary filter requires both the
  first AND last tokens of a candidate phrase to look non-prose
  (uppercase letter, digit, special binder, or long-dot). This
  rejects `на Actions artifacts` and `iPhone 10 сохраняется`
  cleanly while keeping `iPhone 10`, `GitHub Actions`, and
  `Вася Пупкин`.
- **`DictionaryStore.addAutoEntries`** now refreshes `addedAt` on
  duplicate existing entries instead of silently skipping them.
  Frequently-re-encountered auto entries survive the FIFO trim.
  User-source entries refresh keeps the `.user` source intact.
- **First-cap tier minimum length** raised to 5 chars to filter
  short common words (`Так`, `Вот`, `Для`, `Auto`, `Tool`) while
  keeping legitimate brand names (`Slack`, `Apple`, `Anthropic`).
- **Sentence-start detection** uses `NLTokenizer(.sentence)` —
  smarter than the previous punctuation heuristic on
  abbreviations like `т.е.`, `etc.`, `Inc.`.

### Fixed
- **Missing leading space on paste boundary** when transcribing
  into a field whose cursor sits immediately after a non-space
  character. Cleanup pass on Gemini prompt section labels for
  cache stability.

---

## [0.1.2-rc1] — 2026-05-12

First release through the new auto-update pipeline. Functionally
equivalent to 0.1.1; the goal of this RC is to validate end-to-end
that GitHub Actions builds + notarizes + Sparkle-signs the artefact
and that an installed 0.1.1 picks up the new version via the in-app
banner.

### Added
- Sparkle 2 auto-updates. A small "Update to X.Y.Z" banner appears
  in the main window sidebar when a new version is published; click
  to download, verify EdDSA signature, and relaunch on the new build.
- Daily background check via the Sparkle scheduler (no UI to disable
  in this release — auto-only by design for v1).
- CI release pipeline (`.github/workflows/release.yml`): tag `v*`
  triggers build → notarize → sign → publish GitHub Release + patch
  `docs/appcast.xml` on `main`.

---

## [0.1.1] — 2026-05-11

Internal pre-public release.

[Unreleased]: https://github.com/weylandd/NoType/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/weylandd/NoType/releases/tag/v0.1.5
[0.1.4]: https://github.com/weylandd/NoType/releases/tag/v0.1.4
[0.1.4-rc1]: https://github.com/weylandd/NoType/releases/tag/v0.1.4-rc1
[0.1.3]: https://github.com/weylandd/NoType/releases/tag/v0.1.3
[0.1.2-rc1]: https://github.com/weylandd/NoType/releases/tag/v0.1.2-rc1
[0.1.1]: https://github.com/weylandd/NoType/releases/tag/v0.1.1
