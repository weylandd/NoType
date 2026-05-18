---
title: AccessibilityTree fixture-driven tests (closed)
date: 2026-05-15
category: documentation-gaps
module: Context
problem_type: documentation_gap
component: testing_framework
severity: medium
status: closed
applies_when:
  - Historical reference — gap closed by the noise-filtering plan
tags: [accessibility-tree, fixture-tests, mockable, tech-debt, closed]
---

# AccessibilityTree fixture-driven tests (closed)

## Context

No `AccessibilityTreeTests.swift` existed. The tree walker (`NoType/Context/AccessibilityTree.swift`) had subtle invariants — depth cap, per-app node budget, per-app cancellation, total budget, `truncated` flag — that could be locked down with a synthetic graph.

## Guidance

**Closed** by `docs/plans/2026-05-17-002-refactor-ax-tree-noise-filtering-plan.md` (U2 + U4). The right next refactor showed up — adding noise filters and active-app priority — and pulled the testability seams in with it. Rather than the originally-proposed `MockAXNode` + walker-protocol shape (which would have required carving a non-trivial abstraction through `AXUIElementCopyAttributeValue`), the plan extracted two pure seams from inside the walker:

- `AccessibilityTree.decideForNode(role:subrole:title:value:metadata:containingBundleID:depth:) -> NodeDecision` — the per-node pipeline (masker → noise filter → format) as a pure function. Tested directly with synthetic `NodeMetadata` inputs; no AX live calls.
- `AccessibilityTree.applyGlobalCap(dumps:activeBundleID:) -> (apps,totalNodes,truncated)` — the active-first sort + global-budget truncation as a pure function over hand-built `RedactedAppDump` arrays.

Plus `AccessibilityTree.budgetForApp(bundleID:active:) -> Int` for routing rules.

This covered the same invariants the original gap called out (depth, budget, cancellation race, truncation flag) without faking `AXUIElementCopyAttributeValue` — and added new coverage (R8 masker precedence, R5 terminal-parent scrollback gate, R6 pack-collapse negative cases) that the rewritten walker needed anyway.

## Why This Matters

Recorded so a future contributor knows the gap is closed AND that the `MockAXNode`+protocol shape was rejected in favour of seam extraction. If the walker grows again and the existing seams don't cover the new logic, the right move is more seams — not retro-fitting the rejected mock-graph approach.

## When to Apply

Historical reference only.

## Examples

What shipped:

- `NoTypeTests/AXNoiseFilterTests.swift` — 56 cases on the pure predicates (R4 chrome, R5 terminal-parent scrollback, R6 pack-collapse with negative cases, R7 length floor + CJK).
- `NoTypeTests/AccessibilityTreeTests.swift` — 25 cases on the walker's three pure seams (`decideForNode`, `budgetForApp`, `applyGlobalCap`) plus the rendering contract.

## Related

- `docs/plans/2026-05-17-002-refactor-ax-tree-noise-filtering-plan.md` (closing plan, U2 + U4).
- `NoType/Context/CLAUDE.md` "Noise filtering" — invariants now pinned by the new tests.
- `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md` — the underlying multi-app decision.
- Closed in [PR #47](https://github.com/weylandd/NoType/pull/47).
