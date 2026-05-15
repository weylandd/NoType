---
title: Module architecture, DI, and naming conventions
date: 2026-05-15
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: high
applies_when:
  - Creating a new module / folder under NoType/
  - Adding a view-model or service
  - Considering a singleton or DI container
tags: [mvvm, observable, dependency-injection, naming, modules, errors]
---

# Module architecture, DI, and naming conventions

## Context

NoType's architecture rests on three coupled choices: SwiftUI's `Observation` framework for view-models, initializer-only dependency injection for services, and module-owned error types. Mixing patterns (some `ObservableObject`, some `@Observable`; some DI through `@Environment` and some through singletons) is what makes a small app feel inconsistent — this convention pins one shape.

## Guidance

### MVVM with `@Observable`

SwiftUI views observe `@Observable` view-models via `@Environment(Foo.self)` (or a `let` stored property for non-injected references). Use `@Bindable` locally inside `body` when you need a `Binding` (e.g. `Picker(selection: $vm.mode)`).

Current `@Observable` view-models: `AppState`, `PermissionsViewModel`, `OnboardingState`, `AppearanceController`. The `AudioDeviceManager.shared` singleton is also `@Observable`.

**Do not introduce new `ObservableObject` / `@Published` view-models.** They're incompatible with `@Environment(_:)` and force callers to mix patterns.

### Initializer-only dependency injection

Services (`GeminiClient`, `AudioRecorder`, `HistoryStore`) are injected into view-models via initializer. **Never accessed via singleton** — except `AudioDeviceManager.shared` (HAL wrapper, holds no state of its own).

**No property wrappers for DI, no service locators.** Initializer args are the contract; if a view-model takes a `HistoryStore`, you can see it in the signature.

### Modules own their own errors

Each module declares `enum FooError: Error` and surfaces only its own type. **Don't `throw` an `Error` across module boundaries** — translate at the UI seam in `AppState.surfaceError(_:)` via the private `NoTypeErrorKind` table.

### Naming & files

- **One type per file**, named after the type. Exceptions: small private helpers tightly coupled to the main type.
- **Folder = module = (logically) build target boundary** even if we don't split into actual targets yet.
- **Test file mirrors source file**: `Foo.swift` → `FooTests.swift`, all under `NoTypeTests/`.

## Why This Matters

- **`@Observable` over `ObservableObject`** — modern Observation framework integrates with `@Environment(_:)` cleanly; `ObservableObject` requires `@EnvironmentObject` which is a different injection point. Mixing them forces callers to remember which view-model uses which pattern.
- **Initializer DI** keeps the dependency graph visible and testable. Singletons-as-services hide the graph and make swapping implementations in tests painful.
- **Module-owned errors** keep blast radius small. If `HistoryStore` throws, only the History UI cares about the exact case; the rest of the app sees a generic translated message at the seam.
- **One type per file** keeps `grep` and "Jump to file" fast. Multi-type files become haystacks.

## When to Apply

- Default for any new module / view-model / service.
- When touching legacy code that violates one of these — refactor in the same PR if it's a localized fix; otherwise file as tech debt.

## Examples

**Injection at the seam** (from `NoTypeApp.swift` / `MainWindowView`):

```swift
@main struct NoTypeApp: App {
    @State private var appState = AppState(
        historyStore: HistoryStore(...),
        geminiClient: GeminiClient(...),
        // ...
    )
    var body: some Scene {
        Window("NoType", id: "main") {
            MainWindowView().environment(appState)
        }
    }
}

struct SomeChildView: View {
    @Environment(AppState.self) private var appState
    var body: some View { ... }
}
```

**Module-owned error translation** (sketch from `AppState.surfaceError`):

```swift
private enum NoTypeErrorKind {
    case geminiBadKey, geminiQuota, micPermissionMissing, ...
    var payload: ErrorPayload { ... }
}

func surfaceError(_ kind: NoTypeErrorKind) {
    hudController.showErrorHUD(kind.payload)
}
```

## Related

- `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` — Instructions module's adherence to the DI rule.
- `docs/conventions.md` — legacy index, redirects here.
