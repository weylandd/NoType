# Injection module

Pastes the final transcript at the user's cursor via clipboard + ⌘V.

## Files

- `TextInjector.swift` — pipeline: `stitchChunks` + `finalizeForInsertion` + `paste`.
- `PasteboardSnapshot.swift` — captures / restores `NSPasteboard.general` contents across all types.
- `PasteSettings.swift` — typed getter / setter for the restore-delay (50–500 ms; default 150 ms).

## Invariants

1. **Boundary normalisation is client-side source of truth.** The model's leading-space + terminal-punct choices are advisory; `finalizeForInsertion` runs once before paste and corrects deterministically.
2. **`PasteboardSnapshot` captures ALL types** (string, RTF, image, file URL, custom UTI). Restore is faithful.
3. **Restore delay default = 150 ms** (`PasteSettings.defaultRestoreDelayMs`). User-tunable 50–500 ms in 10-ms steps. UserDefaults key `notype.pasteRestoreDelayMs`. Read on every paste — no restart needed.
4. **Inject only on session end**, after all chunks have responded. No mid-recording injection (architecture invariant I5 in `docs/architecture/overview.md`). **And only into the process the user stopped in** — `AppState.finalizeRecording` freezes the frontmost pid at the stop, `RecordingSession.stop()` compares the frontmost pid against it, and on a mismatch never calls `paste` at all (R23 / KD8; the gate lives in `NoType/Recording/`, see its "Destination guard" section). The freeze is at the *stop*, not at session start, so walking to another application mid-recording — the hands-free locked flow — delivers into the application you finished in; what withholds is moving away during transcription. This module is unchanged by either: a withheld paste simply doesn't reach it, so the pasteboard is never captured, never written, and never restored.

## Hard rules

- **Don't repost ⌘V if the first one "didn't work".** No reliable way to know; double-pastes are infuriating.
- **Don't extend the delay automatically based on app.** App-specific tuning was rejected — maintenance burden > problem.
- **Don't write to a private pasteboard name.** ⌘V always uses `.general`. There's no way around this.
- **Don't merge adjacent sentences** inside `finalizeForInsertion`. Not the job; not in v1.
- **Don't strip non-terminal punctuation** (commas / colons / dashes). Model handles those.
- **Don't drop the leading-space defensive path for `InsertionTarget.unknown`.** Electron / web-views routinely come back as `.unknown` and a stray space is much less ugly than glued text.
- **Don't repost into a private pasteboard.** ⌘V binds to `.general`.

## `stitchChunks` rule

Insert a single space between two non-whitespace neighbours at chunk seams, EXCEPT:

1. Next chunk starts with **glue punctuation** (`.`, `,`, `;`, `:`, `!`, `?`) — sticks to the preceding word.
2. Previous chunk ends with a **left-ambiguous symbol** (`—`, `-`, `"`, `'`) — model decides.

Pinned by `TextInjectorTests` under `// MARK: - stitchChunks`. Add a new test for any predicate change.

## `finalizeForInsertion` rule

Single pass, three corrections:

1. **Strip trailing `[.!?]+`** when `textAfter` looks like "inside an existing piece of text" — lowercase first char, continuation punct (`,`, `;`, `:`, `—`, `-`, `…`), or closing bracket / quote (`)`, `]`, `}`, `»`, `"`, `'`, `’`, `”`).
2. **Insert leading space** when `textBefore` ends non-whitespace AND `stitched` starts with a word-opener (letter / digit / quote / opening bracket). Skipped when `stitched` opens with glue punct.
3. **Defensive `InsertionTarget.unknown` branch** (Electron / web-view / Slack composer — `kAXValueAttribute` not exposed): always prepend leading space; skip the trailing-punct strip (textAfter unknown, model's choice stands).

Pinned by `TextInjectorTests` — every branch (strip / no-strip / leading-space / no-leading-space / idempotent / glue / `.unknown`) has a test case.

## Restore-delay matrix

Empirically: AppKit native ~50 ms; Slack / Discord 100–150 ms; heavy Electron 250 ms; iTerm 100 ms. User reports of "NoType pastes my old clipboard" → suggest bumping the slider (200–250 ms covers heavy Electron).

## Failure modes

| Situation | Behaviour |
|---|---|
| Cursor not in a text field / app rejects ⌘V | Paste happens, nothing visible. Toast "could not paste". |
| User cancels mid-session | Don't paste, don't restore. Clipboard unchanged. |
| Empty transcript | Skip injection entirely. Don't touch clipboard. |
| User switched to a different app **after stopping**, while transcribing | `paste` is never called (`RecordingSession.shouldWithholdPaste`). Clipboard untouched; the transcript still goes to its history row. |
| User walked to a different app **while still recording** (hands-free lock) | Normal paste, into the app they stopped in — the destination is frozen at the stop, not at session start. |
| Loses focus permission mid-paste | `CGEvent.post` silently no-ops; clipboard has our text; restore runs. Acceptable. |

## Testing

- `NoTypeTests/PasteboardSnapshotTests.swift` — round-trip various types; verify restore is faithful.
- `NoTypeTests/TextInjectorTests.swift` — stitch + finalize + paste-ordering + timing via stub Pasteboard and mock event-poster.
- No integration test for the actual paste. Manual smoke test before each release: Mail, Slack, Xcode, Safari, Terminal, Notion.

## Pointers

- Why clipboard + ⌘V (not AX text writes) → `solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md`.
- Local chunk concatenation (the source of `stitched`) → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
- Cache-prefix shape (where `Insertion target:` comes from) → `NoType/Gemini/CLAUDE.md`.
- Insertion target capture (security: refuses `AXSecureTextField`) → `NoType/Context/CLAUDE.md`.
