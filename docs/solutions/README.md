# Solutions / Learnings

This directory holds NoType's persistent engineering knowledge in the compound-engineering shape: one decision, learning, or fix per file, with frontmatter that makes the entries searchable by the `ce-learnings-researcher` agent.

## Why per-decision files

- Source of truth for **current behavior** is the code.
- Source of truth for **invariants and conventions** is `CLAUDE.md` (root and per-module).
- Source of truth for **why a decision was made, what we tried, what we rejected, what we learned** is here, one file per decision.

The old monolithic `docs/decisions.md` is being migrated PR-by-PR. ADRs that move land here with a link from the old location.

## Layout

```
docs/solutions/<category>/<slug>-<YYYY-MM-DD>.md
```

Knowledge categories used in NoType today:

| Category folder | When to use |
|---|---|
| `architecture-patterns/` | Large structural decisions: request shape, actor topology, full-screen AX walk, history-store shape. |
| `design-patterns/` | Local design choices: clipboard paste, hotkey detection, single-in-flight Gemini, local concat. |
| `tooling-decisions/` | Third-party / SDK / SKU choices: deployment target, Silero VAD, Gemini SKU, Keychain, distribution channel, Sparkle. |
| `conventions/` | Coding & process conventions: Swift 6 concurrency, force-unwrap policy, telemetry stance. |
| `developer-experience/` | DX rules and recipes: build hard rules, lsregister cleanup, release-script flow. |
| `documentation-gaps/` | Known holes in coverage that aren't bugs. |
| `workflow-issues/` | Friction in how we work. |
| `best-practices/` | Fallback when no narrower bucket fits. |

Bug-track folders (created on first use): `build-errors/`, `test-failures/`, `runtime-errors/`, `performance-issues/`, `database-issues/`, `security-issues/`, `ui-bugs/`, `integration-issues/`, `logic-errors/`.

## Frontmatter contract

The canonical schema lives in the compound-engineering plugin under `skills/ce-compound/references/` (`schema.yaml` + `yaml-schema.md`). Quick reference for the **knowledge track** (most NoType decisions):

Required:

- `title` — clear, descriptive
- `date` — `YYYY-MM-DD`
- `category` — the folder name without trailing slash (e.g. `tooling-decisions`)
- `module` — module or area affected (e.g. `NoTypeApp`, `Gemini`, `Recording`)
- `problem_type` — one of `architecture_pattern`, `design_pattern`, `tooling_decision`, `convention`, `workflow_issue`, `developer_experience`, `documentation_gap`, `best_practice`
- `component` — CE's enum; for NoType, `tooling` is the closest fit for most entries. Other allowed values include `documentation`, `development_workflow`, `testing_framework`, `authentication`
- `severity` — `critical` / `high` / `medium` / `low`

Optional:

- `applies_when` — array, max 5 entries; conditions where the guidance kicks in
- `tags` — array, max 8, lowercase + hyphen-separated
- `related_components` — array
- `symptoms`, `root_cause`, `resolution_type` — bug-track fields; valid on knowledge entries too but not required

YAML safety: any array string that starts with `` ` `` `[ * & ! | > % @ ?` or contains `": "` must be wrapped in double quotes. See `yaml-schema.md` in the plugin for the full ruleset.

## Body structure (knowledge track)

```
# Title (matches frontmatter)

## Context
What situation, gap, or friction prompted this guidance.

## Guidance
The practice, pattern, or recommendation. Concrete.

## Why This Matters
Rationale and impact.

## When to Apply
- Conditions or situations where this applies.

## Examples
Concrete before/after or usage examples.

## Related
- Related solutions, ADRs, or external docs.
```

For bug-track entries use the bug template in the CE plugin's `assets/resolution-template.md` (`## Problem → Symptoms → What Didn't Work → Solution → Why This Works → Prevention → Related Issues`).

## Pilot

The first migrated file is [`tooling-decisions/macos-15-deployment-target-2026-05-15.md`](tooling-decisions/macos-15-deployment-target-2026-05-15.md) — former ADR-001. Subsequent PRs migrate ADR-002..017 in batches, then the per-module `CLAUDE.md` "why" sections, then `TECHDEBT.md`, `conventions.md`, and the load-bearing parts of `architecture.md`.
