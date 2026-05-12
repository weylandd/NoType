import AppKit
import OSLog

@MainActor
enum TextInjector {
    private static let log = Logger(subsystem: "app.notype", category: "injection")

    /// Normalise the model's output against the cursor's actual textual
    /// neighborhood before pasting. The client is the source of truth for
    /// boundary handling (leading space, trailing punctuation) — the
    /// model's per-chunk view is too narrow to get this right reliably,
    /// especially with `thinkingLevel: .minimal`.
    ///
    /// Two concrete corrections:
    ///
    /// 1. **Leading space.** If `textBefore` ends with a non-whitespace
    ///    character and the dictation starts with a word-opener
    ///    (letter/digit/quote/bracket), prepend a single space. The
    ///    system prompt asks the model to do this; in practice it often
    ///    skips it. Idempotent — won't double-up if the model did
    ///    remember.
    ///
    /// 2. **Trailing terminal punctuation.** Strip a trailing `.`/`!`/`?`
    ///    when `textAfter` shows we're inside an existing sentence. The
    ///    "inside an existing sentence" predicate is broader than just
    ///    "starts lowercase": closing brackets, quotes, continuation
    ///    punctuation all count. Keeps the punctuation when `textAfter`
    ///    is empty (cursor at end of document — natural to close) or
    ///    when it starts a clean new sentence.
    ///
    /// Critical for the "no final chunk" path: if the user releases
    /// after >1 s of silence, no `is_final=true` request is sent and the
    /// last non-final chunk's punctuation stands. This is where we patch
    /// it.
    ///
    /// What this does NOT do (deliberate):
    /// - Doesn't touch punctuation between chunks inside `stitched` —
    ///   the model handled that on the basis of `Prior chunks`.
    /// - Doesn't strip non-terminal punctuation (`,`, `;`, `:`, `—`).
    /// - Doesn't merge sentences (e.g. `"...you. In about..."`
    ///   → `"...you, in about..."`). That's a separate normaliser;
    ///   not in v1.
    /// - Doesn't add punctuation if the model omitted it.
    /// Concatenate per-chunk transcripts into the session-wide output.
    ///
    /// Default: insert a single space between two non-whitespace
    /// neighbors at a chunk seam. Two exceptions:
    ///
    /// 1. Next chunk starts with **glue punctuation** (`.,;:!?`) — it
    ///    sticks to the preceding word regardless.
    /// 2. Previous chunk ends with a **left-ambiguous** symbol
    ///    (`—`, `-`, `"`, `'`) — dashes can go either way; straight
    ///    quotes are equally likely opener or closer. Model decides.
    ///
    /// Closing brackets (`)]}»’”`), ellipsis (`…`), letters, digits, and
    /// terminal punctuation all flow through the default path → space
    /// is inserted. This covers two real failure shapes:
    ///
    /// - `"What's up.I'm fine."` — terminal + word.
    /// - `"паузаПродолжай"` — letter + word. The system prompt instructs
    ///   the model NOT to emit terminal punct on mid-thought endings,
    ///   so VAD-pause boundaries routinely land letter-to-letter.
    ///
    /// Known edge: if VAD ever cuts inside a word (rare — Silero pauses
    /// require ≥1 s of silence), we'll insert a spurious space. The
    /// alternative is shipping every pause-bounded session broken for
    /// the common letter-to-letter case.
    nonisolated static func stitchChunks(_ chunks: [String]) -> String {
        let gluedToLeft: Set<Character> = [".", ",", ";", ":", "!", "?"]
        let leftAmbiguous: Set<Character> = ["—", "-", "\"", "'"]

        var out = ""
        for chunk in chunks {
            if let last = out.last, !last.isWhitespace,
               let first = chunk.first, !first.isWhitespace,
               !gluedToLeft.contains(first),
               !leftAmbiguous.contains(last) {
                out.append(" ")
            }
            out.append(chunk)
        }
        return out
    }

    nonisolated static func finalizeForInsertion(
        _ stitched: String,
        textBeforeCursor: String,
        textAfterCursor: String
    ) -> String {
        var out = stitched
        guard !out.isEmpty else { return out }

        // ─── 1. Strip trailing terminal punct when cursor is mid-text ──
        let trimmedRight = textAfterCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuesMidText: Bool = {
            guard let first = trimmedRight.first else { return false }
            if first.isLowercase { return true }
            // Any continuation punctuation: commas, semicolons, dashes,
            // colons, ellipses.
            if [",", ";", ":", "—", "-", "…"].contains(first) { return true }
            // Closing brackets / quotes mean we're inside something —
            // adding terminal punct before them is almost always wrong.
            if [")", "]", "}", "»", "\"", "'", "\u{2019}", "\u{201D}"].contains(first) {
                return true
            }
            return false
        }()
        if continuesMidText {
            let pattern = #"[.!?]+\s*$"#
            if let range = out.range(of: pattern, options: .regularExpression) {
                out.removeSubrange(range)
            }
        }

        // ─── 2. Insert a leading space when textBefore needs one ──────
        // Skip when stitched already starts with whitespace (model
        // remembered) or with punctuation that should glue to the
        // previous word (`.,;:!?`).
        if let lastBefore = textBeforeCursor.last,
           !lastBefore.isWhitespace,
           let firstOut = out.first,
           !firstOut.isWhitespace {
            // Punctuation openers that should NOT get a leading space —
            // they're meant to glue tight to whatever's before them
            // (e.g. trailing comma typed as new dictation, mid-word
            // hyphen, etc).
            let gluePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "—", "-"]
            if !gluePunctuation.contains(firstOut) {
                out = " " + out
            }
        }

        return out
    }

    /// Pastes `text` at the current cursor by saving the user's clipboard,
    /// writing our text, synthesizing ⌘V, and restoring the original
    /// clipboard after `restoreDelayMs`. Empty text is a no-op.
    ///
    /// `restoreDelayMs` defaults to `PasteSettings.restoreDelayMs`, which
    /// is the user-tunable knob from the Settings sheet (clamped to
    /// `PasteSettings.restoreDelayRange`). Callers can override at the
    /// call site for tests; production paths pass nothing.
    static func paste(_ text: String, restoreDelayMs: Int? = nil) async {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        postCommandV()
        let delay = restoreDelayMs ?? PasteSettings.restoreDelayMs
        log.info("paste posted ⌘V (\(text.count) chars, restore in \(delay)ms)")

        try? await Task.sleep(for: .milliseconds(delay))
        snapshot.restore(to: pb)
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // kVK_ANSI_V

        if let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
