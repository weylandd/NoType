# Injection module

Pastes the final transcript at the user's cursor by saving the clipboard, writing our text, synthesizing ⌘V, and restoring the clipboard.

Files:
- `TextInjector.swift` — the injection pipeline (`stitchChunks` + `finalizeForInsertion` + `inject`).
- `PasteboardSnapshot.swift` — captures and restores `NSPasteboard.general` contents across all types.

---

## Why clipboard + ⌘V

See ADR-004. Universal compatibility. AX text injection fails on too many apps; per-character `CGEvent` typing is too slow and breaks IME.

---

## Why chunk assembly is non-trivial

Two product features make the seam logic load-bearing instead of "just concatenate strings":

1. **Mid-thought continuation across VAD pauses.** A single sentence can split across multiple chunks when the user pauses to think. The Gemini system prompt explicitly instructs the model NOT to emit terminal punctuation on dangling phrases, so chunk boundaries routinely land letter-to-letter (`"пауза"` + `"Продолжай"`), not sentence-to-sentence. The model is also supposed to add a leading space on the next chunk in that case, but with `thinkingLevel: .minimal` it often forgets.
2. **Middle-of-text insertion.** The cursor isn't always at the end of an empty field — it can sit between two existing pieces of text (`Text before cursor` / `Text after cursor` from `Insertion target`). The dictated text must read naturally when slotted in: no stray period before a continuation, no double space at the boundary, lowercase first letter when the prior text leaves an open clause.

These two features split across two helpers:
- `stitchChunks` joins per-chunk transcripts → handles (1).
- `finalizeForInsertion` runs once on the stitched result → handles (2).

The boundary normalisation is the source of truth; the model's own choices for leading space and trailing punctuation are advisory.

---

## Chunk stitching (`stitchChunks`)

Each Gemini call returns the text for one chunk (or one contiguous span across a batched call). The session's `transcripts` array holds these in dispatch order. `stitchChunks(_:)` joins them into the session-wide output and inserts the leading space when the model forgot it.

**Rule:** insert a single space between two non-whitespace neighbors at a chunk seam, except in two cases:

1. Next chunk starts with **glue punctuation** (`.`, `,`, `;`, `:`, `!`, `?`) — sticks to the preceding word regardless. Patches `"right." + ",which is great"` → no space.
2. Previous chunk ends with a **left-ambiguous symbol** (`—`, `-`, `"`, `'`) — dashes can go either way; straight quotes are equally likely opener or closer at the seam. Model decides.

Closing brackets (`)`, `]`, `}`, `»`, `’`, `”`), ellipsis (`…`), letters, digits, and terminal punctuation all flow through the default path → space is inserted.

This patches both real failure shapes:
- `"What's up.I'm fine."` → `"What's up. I'm fine."` (terminal + letter)
- `"паузаПродолжай"` → `"пауза Продолжай"` (letter + letter — the common case across VAD pauses, because the system prompt instructs the model NOT to emit terminal punct on mid-thought endings)

Tested in `TextInjectorTests` under the `// MARK: - stitchChunks` section. Add a new test for any predicate change.

### Known edge case

If VAD ever cuts inside a word, this rule inserts a spurious space mid-word. Silero requires ≥1 s of silence to call a pause, so in practice cuts land at phrase boundaries; the system prompt's "rare — VAD cut inside a word" caveat exists but is not observed in normal use. The alternative — shipping every pause-bounded session with `"паузаПродолжай"` seams — is worse.

---

## Client-side boundary normalisation (runs once before inject)

The model's choice of leading space + terminal punctuation is advisory — the client always has more state. Specifically:

- The user can release the hotkey during silence, in which case **no final chunk request is sent**. The last non-final chunk's response may end with a `.` that was correct in isolation but wrong given what comes after the cursor.
- The model may skip the leading space when `textBefore` ends with a non-whitespace character, even though the system prompt asks for it.
- `thinkingLevel: .minimal` (per ADR-003 for transcription latency) makes the model less reliable at multi-step boundary reasoning.

`finalizeForInsertion` is a deterministic, fast post-processor that runs once on `RecordingSession` end, before `paste`. It applies two corrections:

1. **Strip trailing terminal punct** (`.`, `!`, `?`, possibly repeated) when `textAfter` shows we're inside an existing piece of text. The "inside" predicate covers:
   - Lowercase first non-whitespace character
   - Continuation punctuation (`,`, `;`, `:`, `—`, `-`, `…`)
   - Closing brackets / quotes (`)`, `]`, `}`, `»`, `"`, `'`, `\u{2019}`, `\u{201D}`)

   When `textAfter` is empty / whitespace-only, or starts with a terminal mark (`.`, `!`, `?`) or capital letter, terminal punctuation is **kept** — that's the "cursor at end of doc" or "cursor between paragraphs" case where closing the sentence is correct.

2. **Insert leading space** when `textBefore` ends with a non-whitespace character and `stitched` starts with a word-opener (letter/digit/quote/opening-bracket). Idempotent (no double space if `stitched` already starts with whitespace) and skipped when `stitched` opens with glue punctuation (`.`, `,`, `;`, `:`, `!`, `?`, `—`, `-`) — those should sit tight against the previous word.

```swift
func finalizeForInsertion(
    _ stitched: String,
    textBeforeCursor: String,
    textAfterCursor: String
) -> String {
    var out = stitched
    guard !out.isEmpty else { return out }

    // 1. Strip trailing terminal punct when cursor is mid-text.
    let trimmedRight = textAfterCursor.trimmingCharacters(in: .whitespacesAndNewlines)
    let continuesMidText: Bool = {
        guard let first = trimmedRight.first else { return false }
        if first.isLowercase { return true }
        if [",", ";", ":", "—", "-", "…"].contains(first) { return true }
        if [")", "]", "}", "»", "\"", "'", "\u{2019}", "\u{201D}"].contains(first) { return true }
        return false
    }()
    if continuesMidText {
        out.removeRegex(#"[.!?]+\s*$"#)
    }

    // 2. Insert leading space when textBefore ends non-whitespace.
    if let lastBefore = textBeforeCursor.last, !lastBefore.isWhitespace,
       let firstOut = out.first, !firstOut.isWhitespace {
        let glue: Set<Character> = [".", ",", ";", ":", "!", "?", "—", "-"]
        if !glue.contains(firstOut) {
            out = " " + out
        }
    }

    return out
}
```

Things this function does **not** do (and we deliberately don't add):

- It doesn't touch punctuation between chunks inside `stitched` — the model handled that on the basis of `Prior chunks (this session)`.
- It doesn't strip non-terminal punctuation (commas/colons/dashes) — we trust the model's local choices there.
- It doesn't try to merge adjacent sentences (collapse `"...you. In about..."` → `"...you, in about..."`). That's a separate normaliser; not in v1.
- It doesn't add a trailing space. If the model omitted one, the user sees no space against `textAfter` — acceptable; the model usually gets this right.

`TextInjectorTests` pins this contract — every branch (strip, no-strip, leading-space, no-leading-space, idempotent, glue-punctuation) has a test case. Add a new test for any predicate change.

---

## Pipeline

```swift
func inject(_ text: String) async {
    let snapshot = PasteboardSnapshot.capture(.general)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    postCommandV()
    try? await Task.sleep(for: .milliseconds(pasteRestoreDelayMs))
    snapshot.restore(to: .general)
}
```

Caller flow (real shape — see `RecordingSession.stop()`):

```swift
let stitched = transcripts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
let target   = await contextTask?.value.insertionTarget ?? .empty
let final    = TextInjector.finalizeForInsertion(
    stitched,
    textBeforeCursor: target.textBefore,
    textAfterCursor:  target.textAfter
)
await TextInjector.paste(final)
```

`postCommandV()`:

```swift
let src = CGEventSource(stateID: .combinedSessionState)
let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)!  // V = 9
down.flags = .maskCommand
down.post(tap: .cgAnnotatedSessionEventTap)
let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)!
up.flags = .maskCommand
up.post(tap: .cgAnnotatedSessionEventTap)
```

---

## The restore-delay problem

Between "we set the clipboard" and "we restore the clipboard," the target app must have read the pasteboard. If we restore too early, the app pastes the *old* clipboard contents. If we restore too late, the user sees their clipboard "lag" before the app sees our text.

Empirically:
- Native AppKit text views (Mail, Notes, TextEdit): ~50 ms is enough.
- Slack, Discord (Electron): 100–150 ms.
- Some Electron apps with heavy main thread: up to 250 ms.
- Terminal / iTerm: 100 ms.

**Default: 150 ms** (`PasteSettings.defaultRestoreDelayMs`). User-adjustable in the Settings sheet via a slider over `PasteSettings.restoreDelayRange` (50–500 ms in 10 ms steps). The value is stored under `UserDefaults` key `notype.pasteRestoreDelayMs` and read by `TextInjector.paste(_:restoreDelayMs:)` at each call — settings changes take effect on the very next paste, no restart needed.

Files:
- `PasteSettings.swift` — typed getter / setter with clamping to range.
- `SettingsView.swift` — slider control + caption.

If a user reports "NoType sometimes pastes my old clipboard," suggest they bump the slider (200–250 ms covers heavy Electron apps).

---

## PasteboardSnapshot

Captures *all* types on the pasteboard, not just string. People keep images, URLs, file references, custom UTI data. We must restore everything.

```swift
struct PasteboardSnapshot {
    private let items: [PasteboardItem]

    static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = pb.pasteboardItems?.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        pb.writeObjects(items)
    }
}
```

Edge cases:
- Pasteboard is empty → restore writes nothing, fine.
- Item has a "promise" type (large file references) → we copy the data eagerly; if the source app has gone away by restore time, the promise data is what we have. Acceptable.

---

## Edge cases & failure modes

| Situation | Behavior |
|---|---|
| Cursor not in a text field | Paste happens but nothing visible. Toast: "could not paste". |
| Frontmost app doesn't accept ⌘V | Same — toast. |
| User presses ⌘V manually during the 150 ms window | Their paste fires before ours; ours fires too. Rare and self-inflicted. |
| User cancels the session (e.g. quits NoType mid-recording) | Don't paste, don't restore. Clipboard stays unchanged. |
| Empty transcript | Skip injection entirely. Don't touch clipboard. |
| NoType loses focus permission mid-paste | `CGEvent.post` silently no-ops. Clipboard already has our text; restore still runs. User sees their clipboard contains our text. Acceptable degradation. |

---

## What NOT to do

- **Don't repost ⌘V if the first one "didn't work".** We have no reliable way to know it didn't, and double-pastes are infuriating.
- **Don't extend the delay automatically based on app.** App-specific tuning was considered and rejected — the maintenance burden is worse than the problem.
- **Don't write to a private pasteboard name and ⌘V from there.** ⌘V always uses `.general`. There's no way around this.

---

## Testing

`InjectionTests/`:
- `PasteboardSnapshotTests.swift` — round-trip various types (string, RTF, image, file URL, custom UTI). Verify restore is faithful.
- `TextInjectorTests.swift` — uses a stub `Pasteboard` and a mock event-poster to verify ordering and timing.
- No integration test for the actual paste — that requires a target app, which we don't automate.

Manual smoke test before each release: paste into Mail, Slack, Xcode, Safari, Terminal, and a known-flaky Electron app (e.g. Notion). Verify text arrives correctly and original clipboard is restored.
