import Foundation

/// Pure, deterministic find/replace pass over the final transcript.
/// Applied once in `RecordingSession.stop()` between `finalizeForInsertion`
/// and `TextInjector.paste` so the pasted text — and the history entry —
/// reflect the user's canonical spellings.
///
/// Matching is **word-boundary**, case-sensitive on `from`, with one
/// auto-generated variant: when `from` starts with a lowercase letter,
/// we also match the capitalized form (only the first character) and
/// replace it with a capitalized variant of `to`. Concretely, a pair
/// `то есть → т.е.` produces these match→output pairs:
///
/// - `то есть` → `т.е.`
/// - `То есть` → `Т.е.`
///
/// All-caps (`ТО ЕСТЬ`) is intentionally not matched — capitalization
/// in the user's input only generates one extra variant, not the full
/// stress-test set. The user can add an explicit pair if they need it.
///
/// Word boundaries are ICU-aware (`NSRegularExpression`'s `\b` uses
/// Unicode word-character classes), so Cyrillic and other non-ASCII
/// alphabets work as expected — `то есть` won't match inside `кто
/// есть`.
///
/// Each pair is applied **sequentially to the running result**, so later
/// pairs see the output of earlier ones — they cascade. `ML → machine
/// learning` followed by `learning → studying` therefore produces
/// `machine studying`, because the second pair's regex runs against the
/// text the first pair already rewrote. This is deliberate: pairs apply
/// in creation order and the user controls that order. The trade-off is
/// that overlapping pairs can chain in surprising ways — predictable
/// ordering was chosen over trying to detect and block cascades.
enum TextReplacementEngine {

    /// Apply `replacements` to `text` and return the result. Pairs run in
    /// `replacements` order (creation order), each as a single regex pass
    /// over the **running** result. A pair never re-scans its own output,
    /// but a *later* pair whose `from` appears in an *earlier* pair's `to`
    /// WILL match — the pairs cascade in creation order. Ordering is the
    /// user's control.
    static func apply(_ text: String, replacements: [DictionaryReplacement]) -> String {
        guard !text.isEmpty, !replacements.isEmpty else { return text }

        // Process pairs sequentially, but each pair sees the result of
        // prior pairs. We protect against cascade by performing a single
        // regex pass per pair (NSRegularExpression matches against the
        // current state then replaces atomically), not by re-scanning
        // after each substitution. So `ML → machine learning` followed
        // by `learning → studying` produces `machine learning` on the
        // first pass and the second pair's regex sees the new text —
        // which DOES match. To avoid that explicit cascade we'd need to
        // mark-and-replace via placeholders; for now we accept the
        // ordering effect because the documented contract is exactly
        // "pairs apply in the order they were created".
        var out = text
        for pair in replacements {
            out = applySingle(out, pair: pair)
        }
        return out
    }

    /// Apply a single replacement pair to `text`. Generates the
    /// capitalized variant when applicable.
    private static func applySingle(_ text: String, pair: DictionaryReplacement) -> String {
        let from = pair.from
        let to = pair.to
        guard !from.isEmpty else { return text }

        var out = text
        out = replaceWordBoundary(in: out, find: from, with: to)

        // Auto-capitalized variant: only when the first character is a
        // lowercase letter. The variant capitalizes only the first
        // character (not full title-case, not all-caps); that mirrors
        // how the user expects "Сегодня" / "Сегодня," / "Сегодня!" to
        // be picked up after "сегодня → ...".
        if let firstFrom = from.first, firstFrom.isLowercase {
            let capFrom = String(firstFrom).uppercased() + from.dropFirst()
            let capTo: String
            if let firstTo = to.first, firstTo.isLowercase {
                capTo = String(firstTo).uppercased() + to.dropFirst()
            } else {
                capTo = to
            }
            out = replaceWordBoundary(in: out, find: capFrom, with: capTo)
        }
        return out
    }

    /// Word-boundary replacement using `NSRegularExpression`. The
    /// pattern is `\b<escaped find>\b`; ICU's `\b` covers Unicode word
    /// characters, so Cyrillic / Greek / etc. work without extra
    /// plumbing. `find` is escaped, so dots, plus signs, brackets etc.
    /// are treated literally. The replacement template needs separate
    /// escaping because regex replacement honours `$0..$9` and `\$`.
    private static func replaceWordBoundary(in text: String, find: String, with replacement: String) -> String {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: find) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: escapedReplacement
        )
    }
}
