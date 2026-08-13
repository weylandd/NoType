# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

Each entry must stand on its own for a reader with no access to the code, so entries carry **no file paths, type or function names, and no current-config values** (thresholds, counts, enum values) — state the behaviour, not the number. Those live in the per-module `CLAUDE.md` files and in `docs/solutions/`.

Seeded from the dictation-delivery area (capture → transcription → delivery). Other areas — context capture, the personal dictionary, updates, permissions — are not yet represented; add their core nouns when a learning touches them.

## Dictation

### Recording session
One dictation: everything from the user starting the hotkey to the moment they stop it, plus the transcription and delivery that follow. Usually that is a single hold of the key — but a session can also be *locked*, in which case start and stop are two separate gestures that may happen at different times and in different applications. It is the unit almost every rule in this project is scoped to — one context snapshot, one frozen set of instructions and dictionary entries, one stitched transcript, one delivery.
*Avoid:* "session" unqualified, when a network session could also be meant.

A recording session is a value with a lifetime, not a global: it is created when recording starts and dropped after delivery, and there is no "current session" singleton. Text is delivered at the end, never mid-session, and **at most** once — a delivery aimed at an application the user has since left is withheld rather than pasted.

### Locked session
A recording session that keeps running hands-free after the user lets go of the hotkey, until a separate deliberate stop. It exists so a long dictation does not require holding a key down, and so the user can move around while talking.

It is the mode in which a session's start and its end stop being the same event: the user can begin dictating in one application, walk to another, and stop there. Any fact captured at the start on the assumption that nothing moves is wrong for a locked session — which is why the place a transcript is delivered to is decided at the stop, not at the start.

### Paste destination
The application a finished transcript is delivered into: the one frontmost at the moment the user *stopped*, not the one the dictation began in. For an ordinary hold-to-talk dictation those are the same; for a locked session they routinely differ, and the stop is the one that counts, because stopping somewhere is how the user aims the text.

Transcription takes time, so the destination is checked once more immediately before the text is typed. If the user has moved on in the meantime, the delivery is **withheld** — nothing is typed into a document they never meant to edit, and the transcript is kept on its history row instead, with a notice naming where it had been headed. A withheld delivery is a designed outcome, not a failure, but it is never a silent one: the user was expecting text to appear somewhere and it did not.

Where the dictation *happened* is a different fact, recorded separately for per-application statistics, and it stays fixed at the start even though the destination does not.

### Chunk
A slice of a recording session's audio, cut at a natural speech pause, that is transcribed as one unit. A session produces one chunk per pause plus a final one on release; a long unbroken monologue is force-cut so no chunk grows unbounded.

Chunks are transcribed in order and at most one transcription request is outstanding per recording session, so chunks that pile up during a slow request are sent together as one batch. Each request returns only its own chunk's text — the full transcript is joined locally, never re-emitted by the model.

### Gap
A position in a transcript where a chunk's transcription failed in a way that could plausibly succeed on a retry. It marks a hole in otherwise-usable text rather than discarding the whole dictation.

A gap is what makes partial delivery possible: the surviving chunks are delivered, and the transcript's row is recorded as broken so the lost audio — which is held in memory, never written to disk — can be re-sent into exactly that position. A failure that no retry could fix produces no gap; it ends the session instead. Delivery is the usual case but not the guaranteed one: a dictation whose destination changed while it was transcribing is withheld rather than pasted, and then the surviving chunks reach the user through the history row instead.

**A gap is a position; the *gap marker* is only how one looks.** The marker — `[…]` — is drawn wherever a gap sits when a transcript is rendered, and the user's dictionary replacement pairs may restyle it like any other text. Nothing structural is read back out of those characters: whether a row is broken, how many chunks it lost, and where a recovery belongs are all answered from the stored positions. This distinction was learned by shipping the other one, where the marker *was* the storage and an ordinary replacement pair on the ellipsis silently erased the user's ability to recover.

### Network class
The failure class meaning *the transport itself did not answer* — nothing came back from the server, as opposed to the server answering with a refusal or an error. It is distinguished from every other failure because it is the only one where the connection itself is suspect, so it is the only one whose retry is issued over a fresh connection rather than the one that just went silent.

Distinct from a rate-limit or a server error: those came *back* over a demonstrably working connection, so they are retried as-is. *Offline* — the system reporting no network path at all — is answered without issuing a request at all, but it deliberately reports itself downstream as this same class, so that nothing after the point of failure has to know the difference.

### Notice
The one transient panel a finished dictation raises to tell the user something they would otherwise have to infer — that chunks were lost to gap markers, or that delivery was withheld because they had moved on. An ordinary dictation that delivered everything raises none.

**At most one per dictation, and that is a constraint rather than a habit:** a second notice *replaces* the first rather than stacking beside it, so raising two silently discards one. Which one survives is therefore a decision made up front, not an accident of which code path ran last. A notice names the cause and then the consequence; only the consequence varies with what was kept, because the cause is the only place the user ever learns *why* — the history row deliberately does not carry it. A notice offers an action only where the surface it points at offers the same one: a panel promising something the row will not do is worse than a panel promising nothing. Because the panel draws over whatever application the user has moved to — possibly a screen share or a call — it never renders any of the transcript itself.

## Flagged ambiguities

- **"session"** had been used for both a recording session and the long-lived HTTP session shared by every call to the transcription API — including calls that are not part of any dictation. These are unrelated, and a rule scoped to one says nothing about the other. Qualify the word whenever both are in scope.
