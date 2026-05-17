---
title: Right Option as push-to-talk via CGEventTap
date: 2026-05-15
category: design-patterns
module: Hotkey
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - Adding or rebinding the push-to-talk hotkey
  - Considering NSEvent global monitors for any hotkey path
  - Choosing a default modifier-only hotkey for a new feature
tags: [hotkey, cgeventtap, modifier-key, push-to-talk, accessibility-permission]
---

# Right Option as push-to-talk via CGEventTap

## Context

NoType needs a global push-to-talk hotkey that:

- Fires on **press** and **release** (modifier-only, held).
- Doesn't conflict with common shortcuts.
- Distinguishes left vs right of a paired modifier.
- Is reliable across focus state and busy main runloops.

## Guidance

**Default binding: Right Option.** **Detection: `CGEventTap` on `flagsChanged`**, distinguishing left vs right by the per-side modifier bit in `event.flags.rawValue`:

- Right Option: `0x40` (`NX_DEVICERALTKEYMASK`)
- Left Option: `0x20` (`NX_DEVICELALTKEYMASK`)

The tap is installed on a **dedicated `Thread` with its own `RunLoop`** — never on the main runloop (see `NoType/Hotkey/CLAUDE.md` for why).

## Why This Matters

**Modifier-only hotkeys cannot be reliably caught with `NSEvent.addGlobalMonitorForEvents`.** The system delivers `flagsChanged` events through it inconsistently — works for some users, fails for others, depends on focus state. Users would report "hotkey randomly stops working" with no reproducible pattern.

**`CGEventTap` is the only stable mechanism for modifier-only press/release.** It needs Accessibility permission, but NoType needs that anyway for the AX tree (see `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`) — so the cost is zero.

**Right Option is rare and unobtrusive.** Most users don't have it bound to anything; the macOS `™ © °` characters it normally types are sacrificed during the press, but those users can rebind post-v1.

**Per-side bit math beats keyCode reads.** Reading `event.getIntegerValueField(.keyboardEventKeycode)` works but the bit-mask path is shorter and avoids a syscall. KeyCodes (`kVK_RightOption = 61`, `kVK_Option = 58`) are recorded only for reference.

## When to Apply

- **Default push-to-talk binding.** Right Option held → press/release via `CGEventTap` on `flagsChanged`, bit-mask on `0x40` / `0x20`.
- **User-configurable bindings (PR #43, shipped).** `HotkeyBinding` is a `struct` (not enum, as originally sketched) with a JS-style `code: String` (e.g. `"AltRight"`, `"KeyR"`, `"F12"`), persisted to `UserDefaults` under `notype.hotkey.bindingCode`. `HotkeyMonitor` is parametrised on the binding:
  - **Modifier bindings** (`AltRight`, `ControlLeft`, `ShiftLeft`, `MetaRight`, `Fn`, …) keep the `flagsChanged` bit-mask path. The per-side device bit is looked up via `HotkeyBinding.modifierBit` rather than hard-coded.
  - **Non-modifier bindings** (e.g. `KeyR`, `F12`, `Space`) switch to virtual-key matching on `keyDown` / `keyUp` events, comparing against `HotkeyBinding.virtualKeyCode`. `nonModifierHeld` collapses macOS's auto-repeated `keyDown` events so the session sees a single press/release pair.
  - **Escape** (`kVK_Escape = 53`) stays hard-wired to `onEscape` regardless of binding — single cancellation hotkey for in-flight sessions. `HotkeyBinding.isAllowedAsHotkey` rejects Escape / Power / CapsLock so a user can't pick a key that would shadow the cancellation path.
  - The `CGEventTap`-on-dedicated-thread structure stays. Live rebinding tears the old monitor down (`HotkeyMonitor.stop()`) and starts a new one (`AppState.applyHotkeyBinding(_:)`).
- **Multi-key combos (e.g. `⌃⇧Space`)** are NOT supported by the current `HotkeyBinding` shape — `code: String` is a single identifier. Combos remain a future expansion (would need either a `[String]` codes field or an explicit `modifiers + base` pair).

## Examples

**Detection helper (testable, pure function):**

```swift
static let rightOptionBit: UInt64 = 0x40

static func detectTransition(prev: UInt64, curr: UInt64) -> Transition {
    let p = (prev & rightOptionBit) != 0
    let c = (curr & rightOptionBit) != 0
    switch (p, c) {
    case (false, true):  return .pressed
    case (true,  false): return .released
    default:             return .none
    }
}
```

**Trade-off accepted:** Right Option's `™ © °` characters are suppressed during press. Users who need them can rebind post-v1.

**Alternatives that were rejected:**

- **`⌃⇧Space` or other multi-key binding for v1 default.** Viable, but worse UX (two-hand combo). Will become configurable post-v1.
- **`NSEvent.addGlobalMonitorForEvents`.** Rejected — does not reliably emit for modifier-only events.

## Related

- `NoType/Hotkey/HotkeyBinding.swift` — the canonical landed value type (PR #43).
- `NoType/Hotkey/HotkeyMonitor.swift` — the parametrised monitor; `stop()` invalidates the tap + stops the runloop for clean rebinds.
- `NoType/Hotkey/CLAUDE.md` — runloop / tap-restoration details, `tapDisabledByTimeout` recovery, Escape cancellation flow.
- `docs/decisions.md` ADR-005 — legacy index entry, redirects here.
- `solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md` — the same `CGEvent` API on the output side.
