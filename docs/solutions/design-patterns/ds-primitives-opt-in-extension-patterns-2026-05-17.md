---
title: Backwards-compatible extension patterns for DS primitives
date: 2026-05-17
category: design-patterns
module: UI
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - Adding a new size variant to an existing DSComponents button or chip
  - Extending DSGlyphChip or another DS primitive with additional visual parameters for a new surface
  - "Introducing a derived dynamic-color token in DesignTokens.swift that would naturally be expressed as `existingToken.opacity(x)`"
  - Wrapping Color.opacity() over a dynamic NSColor at file-scope static let — prefer explicit per-theme RGBA tuples to avoid resolved-sRGB freezing risk
  - Adding an accessibility override parameter to a DS primitive whose visible label changes mid-lifecycle
tags: [swiftui, design-system, backwards-compatibility, component-evolution, dscomponents, designtokens, opt-in-defaults]
---

# Backwards-compatible extension patterns for DS primitives

## Context

NoType's UI module enforces two standing constraints via `UI/CLAUDE.md` Hard rules: (1) all visual values must flow through `DesignTokens.swift` — never inline raw hex or `.opacity(_:)` literals at call sites — and (2) any button, chip, or pill that appears in two or more surfaces must live in `DSComponents.swift`. These rules make `DSComponents.swift` the single source of truth for shared primitives: `DSPrimaryButton`, `DSSecondaryButton`, `DSGlyphChip`, `DSCloseButton`, and friends, used by every HUD, the popover, the main window, and (as of PR #43) five onboarding screens.

When the onboarding wizard was first wired up, step files contained hand-rolled inline components: a custom 44 pt icon tile, a custom 36 pt footer CTA, and a custom 28 pt row CTA — each duplicating visual idioms already present in the shared primitives. Code review flagged all three as violations of the "second use → refactor" rule and requested that the shared components be extended instead.

The unifying principle behind all four techniques introduced in that PR: **new behavior is opt-in via defaults, so every existing caller gets identical behavior without modification.** The HUDs that use `DSPrimaryButton` / `DSGlyphChip` in their original 24 pt / 26 pt shapes were never touched. Only the new onboarding call sites pass the new parameters.

## Guidance

### 1. Add a `Size` enum (or categorical knob) to scale an existing component

Use when the same component needs to render at multiple visual scales with otherwise-identical behavior. The new enum must default to the pre-extension value, so every existing call site that omits the argument gets the original look with zero code change.

```swift
struct DSPrimaryButton: View {
    enum Size { case small, medium, large }
    let label: String
    var size: Size = .small   // default preserves the original HUD shape
    // ...
}
```

Geometry derivations (height, padding, font size, radius, spacing) live in a `fileprivate` extension at the bottom of the file — kept out of the struct body to separate "what the component does" from "how it measures itself". When only one case in a switch differs from the others, collapse to a ternary rather than three switch arms, and add an inline comment explaining why:

```swift
extension DSPrimaryButton.Size {
    fileprivate var height: CGFloat {
        switch self {
        case .small:  return 24
        case .medium: return 28
        case .large:  return 36
        }
    }
    // `.small` and `.medium` share the HUD radius / content-spacing; only
    // `.large` (the onboarding footer CTA) bumps up. Expressed as a
    // boolean rather than three identical switch arms so it's obvious
    // when a future medium-tuning change would need a real third value.
    fileprivate var contentSpacing: CGFloat { self == .large ? 6 : 5 }
    fileprivate var cornerRadius:   CGFloat { self == .large ? 8 : 6 }
}
```

`DSSecondaryButton` re-uses the same `Size` via a `typealias` so the two buttons stay in sync without duplicating the geometry table:

```swift
struct DSSecondaryButton: View {
    typealias Size = DSPrimaryButton.Size
    var size: Size = .small
    // ...
}
```

### 2. Add optional parameters with defaults that preserve the existing shape

Use when only one or a few call sites need a new knob. Existing callers don't pass it; new callers do. The default values must match the pre-extension hardcoded values — not "sensible defaults" in the abstract, but the exact values the component was already rendering so the visual diff at all existing call sites is zero.

`DSGlyphChip` originally hardcoded `cornerRadius: 8`, `symbolSize: 13`, `symbolWeight: .semibold`, and no border. The onboarding permission rows needed a 44 pt tile with 10 pt radius, 18 pt symbol, regular weight, and a hairline border. Rather than forking the component:

```swift
struct DSGlyphChip: View {
    let severity: Severity
    let symbol: String
    var size: CGFloat = 26                                  // HUD original: 26
    var cornerRadius: CGFloat = 8                           // HUD original: 8
    var symbolSize: CGFloat = 13                            // HUD original: 13
    var symbolWeight: SwiftUI.Font.Weight = .semibold       // HUD original: .semibold
    var showBorder: Bool = false                            // HUD original: no border
    var withPulse: Bool = false                             // pre-existing param; unchanged
}
```

The three HUD call sites that existed before the PR were never touched. The onboarding permission row passes all four new knobs explicitly:

```swift
DSGlyphChip(
    severity: glyphSeverity,
    symbol: symbol,
    size: 44,
    cornerRadius: 10,
    symbolSize: 18,
    symbolWeight: .regular,
    showBorder: true
)
```

### 3. Add a state-aware `*Override: T? = nil` parameter for accessibility identity stability

Use when a component's visible label or content changes during its lifecycle but the VoiceOver-announced identity should stay stable. An `Optional` override with a `nil` default costs nothing at existing call sites; new call sites set it explicitly.

`DSPrimaryButton` gained `accessibilityLabelOverride: String? = nil`. The accessor is a single ternary in the `.accessibilityLabel` modifier:

```swift
var accessibilityLabelOverride: String? = nil
// ...
.accessibilityLabel(accessibilityLabelOverride ?? label)
```

The API-key step's Continue button sets it because the visible label flips to "Validating" during the async key check:

```swift
DSPrimaryButton(
    label: validating ? "Validating" : "Continue",
    size: .large,
    isLoading: validating,
    isEnabled: continueEnabled,
    // Keep VoiceOver pinned to "Continue" so the announced
    // identity doesn't churn when the visible label flips to
    // "Validating" during the API-key check.
    accessibilityLabelOverride: "Continue",
    action: continueTapped
)
```

Without the override, VoiceOver would announce "Validating button" mid-flight — confusing for users who activated the button. With it, the announcement stays "Continue button" throughout, matching what the user intentionally tapped.

### 4. For derived dynamic-color tokens, use explicit per-theme RGBA tuples rather than `.opacity()` chains

Use when defining a new `DS.Color.*` constant that is a tinted derivative of an existing dynamic color. The risk: `SwiftUI.Color` backed by a dynamic `NSColor` provider resolves its sRGB values lazily. Wrapping such a value in `.opacity(_:)` at `static let` scope **may** freeze the resolved appearance at first access on some SwiftUI / macOS version combinations, producing a token that does not flip correctly on light↔dark appearance changes.

The claim is debatable — empirical verification is pending and the bug may not manifest on currently-shipped macOS versions — but the defensive fix is free. Spell out the RGBA per theme using the same `dsDynamic(lightRGBA:darkRGBA:)` helper the rest of the design token system uses. The comment documents both the anchor token and the alpha rung so a future reviewer can verify the derivation:

```swift
// Onboarding-chrome derivatives — the centered progress pill
// background and the pending-dot fill. Expressed as explicit
// per-theme RGBA so the dynamic NSColor provider re-resolves on
// appearance flips. (Wrapping a dynamic color in
// `SwiftUI.Color.opacity(_:)` at static-let scope risks freezing
// the sRGB at first access — safer to spell out the tuple.)
// Anchors:
//   bgBase light=#FEFCF9, dark=#0D0E11 @ 60%
//   textQuaternary light=#909297, dark=#6E6D76 @ 55%
static let progressPillFill   = SwiftUI.Color.dsDynamic(
    lightRGBA: (254/255, 252/255, 249/255, 0.60),
    darkRGBA:  ( 13/255,  14/255,  17/255, 0.60)
)
static let progressDotPending = SwiftUI.Color.dsDynamic(
    lightRGBA: (144/255, 146/255, 151/255, 0.55),
    darkRGBA:  (110/255, 109/255, 118/255, 0.55)
)
```

Compare to the fragile alternative these replaced:

```swift
// Possibly fragile — may freeze resolved sRGB at first access:
static let progressPillFill   = DS.Color.bgBase.opacity(0.60)
static let progressDotPending = DS.Color.textQuaternary.opacity(0.55)
```

The same principle applies to `accentDisabled` (40% accent) and `dangerSoftStrong` (40% danger soft), both of which are defined with explicit tuples for the same reason.

## Why This Matters

- **Existing callers don't need to be hunted down on every extension.** `DSGlyphChip` is used in four HUDs and the onboarding step. A new size requirement at one surface — without the default-preserving pattern — would require auditing all four HUD call sites to confirm nothing regressed. With defaults that preserve the prior shape, the audit is "did I change any default?" which is a one-line diff check.
- **The DS file becomes self-documenting about available knobs.** A reviewer reading `DSGlyphChip(severity: ..., symbol: ..., size: 44, cornerRadius: 10, symbolSize: 18, symbolWeight: .regular, showBorder: true)` immediately sees the full knob set and which ones this call site is overriding. The alternative — an inline `ZStack { RoundedRectangle … Image(systemName: …) }` at the call site — hides all of that: shape, sizing, severity tint, and border behavior are implicit, and the next engineer has to rediscover them.
- **It compounds.** The `Size` enum paid for once covers every future surface at those heights. The onboarding hotkey-check step's footer CTA is `DSPrimaryButton(.large)` — zero new code.
- **Accessibility doesn't degrade silently.** The `accessibilityLabelOverride` pattern makes "this label is intentionally mutating, but VoiceOver identity should stay X" explicit at the call site. Without it, the behavior is accidental — sometimes the announced label is correct, sometimes it churns — and it requires active testing to notice.
- **Theme-aware tokens stay theme-aware.** The explicit-RGBA rule for derived dynamic colors removes a class of "looks fine in dark, subtly broken in light" bugs that are easy to introduce and hard to catch in automated tests.

## When to Apply

- **Adding a new size variant to an existing `DSComponents` button or chip.** If the component is already used at one height and a new surface needs it at a different height, introduce a `Size` enum rather than forking or inlining. Default the enum to the existing height.
- **Extending an existing primitive with one or more knobs needed only by a single new surface.** If the new knob's "off" value matches the component's current hardcoded value, make it an optional parameter defaulting to that value. The first inline copy of a component is acceptable; the second triggers the "move to DSComponents" rule from `UI/CLAUDE.md`, and when moving it, bring the new knob into the shared definition rather than the call site.
- **Introducing a new dynamic-color token derived from an existing one.** Don't write `DS.Color.someDynamicToken.opacity(x)` as a `static let` declaration. Use `dsDynamic(lightRGBA:darkRGBA:)` with the anchor RGB values spelled out per theme and a comment documenting the derivation.
- **Adding an accessibility override for a component whose visible state changes mid-lifecycle.** Any time a button's label or a chip's content is bound to a state variable that can flip while the component is on screen, evaluate whether the VoiceOver identity should stay stable. If yes, add an `*Override: T? = nil` param rather than letting the announced text follow the visible state implicitly.

## Examples

### Technique 1 — `Size` enum (before / after)

**Before — hand-rolled inline CTA in the wizard's first draft:**

```swift
Text("Continue")
    .font(.system(size: 14, weight: .medium))
    .foregroundStyle(DS.Color.textOnAccent)
    .padding(.horizontal, 14)
    .frame(minWidth: 180, minHeight: 36)
    .background(isEnabled ? DS.Color.accent : DS.Color.accent.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 8))
```

**After — shared `DSPrimaryButton(.large)`, zero geometry at the call site:**

```swift
DSPrimaryButton(
    label: "Continue",
    size: .large,
    trailingSystemSymbol: "arrow.right",
    isEnabled: permissions.allGranted,
    minWidth: 180
) {
    if permissions.allGranted { onboarding.goNext() }
}
```

### Technique 2 — optional params with defaults (before / after)

**Before — hand-rolled 44 pt tile inline:**

```swift
ZStack {
    RoundedRectangle(cornerRadius: 10)
        .fill(tintFill)
        .frame(width: 44, height: 44)
    RoundedRectangle(cornerRadius: 10)
        .strokeBorder(tintBorder, lineWidth: 0.5)
        .frame(width: 44, height: 44)
    Image(systemName: symbol)
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(tintFg)
}
```

**After — extended `DSGlyphChip` with default-preserving params; HUD callers untouched:**

```swift
DSGlyphChip(
    severity: glyphSeverity,
    symbol: symbol,
    size: 44,
    cornerRadius: 10,
    symbolSize: 18,
    symbolWeight: .regular,
    showBorder: true
)
```

### Technique 3 — `accessibilityLabelOverride` (before / after)

**Before — VoiceOver announces the mutating visible label:**

```swift
DSPrimaryButton(
    label: validating ? "Validating" : "Continue",
    size: .large,
    // VoiceOver would say "Validating button" mid-flight
    action: continueTapped
)
```

**After — VoiceOver identity pinned through the validation state:**

```swift
DSPrimaryButton(
    label: validating ? "Validating" : "Continue",
    size: .large,
    isLoading: validating,
    isEnabled: continueEnabled,
    accessibilityLabelOverride: "Continue",  // VoiceOver stays "Continue button"
    action: continueTapped
)
```

### Technique 4 — explicit RGBA for derived dynamic tokens (before / after)

**Before — `.opacity()` chain on a dynamic-NSColor-backed `Color` at static-let scope:**

```swift
static let progressPillFill   = DS.Color.bgBase.opacity(0.60)
static let progressDotPending = DS.Color.textQuaternary.opacity(0.55)
```

**After — explicit per-theme tuples; the dynamic NSColor provider re-resolves on appearance flips:**

```swift
static let progressPillFill   = SwiftUI.Color.dsDynamic(
    lightRGBA: (254/255, 252/255, 249/255, 0.60),  // bgBase light @ 60%
    darkRGBA:  ( 13/255,  14/255,  17/255, 0.60)   // bgBase dark  @ 60%
)
static let progressDotPending = SwiftUI.Color.dsDynamic(
    lightRGBA: (144/255, 146/255, 151/255, 0.55),  // textQuaternary light @ 55%
    darkRGBA:  (110/255, 109/255, 118/255, 0.55)   // textQuaternary dark  @ 55%
)
```

## Related

- `NoType/UI/CLAUDE.md` Hard rules — "All visual values via DesignTokens" and "If a button / chip / pill appears in 2+ surfaces with the same spec, it lives in DSComponents.swift." These are the standing constraints that make the patterns in this document necessary.
- [`../conventions/module-architecture-and-naming-2026-05-15.md`](../conventions/module-architecture-and-naming-2026-05-15.md) — No `ObservableObject` / `@Published` view-models; `@Observable` + `@Environment(_:)` is the pattern. Kindred convention: both rules keep the shared layer clean and call sites simple.
- [`../runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md`](../runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md) — prior example of a `UI/` module consolidation (two spectrum meters → one `SpectrumMeter`). Different problem domain (concurrency crash, not component evolution) but the extraction-rather-than-fork model is analogous.
- [`../conventions/swift-6-concurrency-and-async-2026-05-15.md`](../conventions/swift-6-concurrency-and-async-2026-05-15.md) — Swift 6 strict concurrency context. The `fileprivate` geometry extensions and `@State`-only mutation inside DS components are consistent with this convention.
