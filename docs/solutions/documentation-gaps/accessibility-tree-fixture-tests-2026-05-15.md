---
title: AccessibilityTree fixture-driven tests (planned)
date: 2026-05-15
category: documentation-gaps
module: Context
problem_type: documentation_gap
component: testing_framework
severity: medium
applies_when:
  - Refactoring AccessibilityTree's walk / depth / cancellation logic
  - Investigating a regression in AX context quality or budget overruns
tags: [accessibility-tree, fixture-tests, mockable, tech-debt]
---

# AccessibilityTree fixture-driven tests (planned)

## Context

No `AccessibilityTreeTests.swift` exists. The tree walker (`NoType/Context/AccessibilityTree.swift`) has subtle invariants — depth cap, per-app node budget, per-app cancellation, total budget, `truncated` flag — that could be locked down with a synthetic `MockAXNode` graph driving the walk via a thin protocol.

## Guidance

When the next refactor lands on the walker (e.g. tightening the per-app deadline check), introduce the mock graph protocol and write the regression tests at the same time. **Don't introduce the protocol on its own** — wait for a real change that benefits from it.

## Why This Matters

The walker has been stable since launch; nothing has regressed it. But refactoring without tests is the kind of thing that ships invisible regressions — a `truncated` flag that flips spuriously, a per-app budget that's off-by-one, a deadline that no longer fires.

## When to Apply

- Any PR that materially changes the walk algorithm (depth, breadth, cancellation, budget).
- Any PR that introduces a new node category to the dump (e.g. a richer secure-field heuristic).

## Examples

The shape would be:

- A `MockAXNode` value type with `role`, `subrole`, `value`, `children`, etc.
- A protocol the walker uses to descend nodes (instead of calling `AXUIElementCopyAttributeValue` directly).
- ~10 test cases covering depth cap, budget overflow, cancellation race, truncation flag.

Approximate effort: **M**.

## Related

- `NoType/Context/CLAUDE.md` "What we walk" — the invariants the tests would pin.
- `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md` — the underlying decision.
- `docs/TECHDEBT.md` — legacy index entry, redirects here.
