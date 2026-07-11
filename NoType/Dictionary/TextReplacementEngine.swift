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
/// Word boundaries use a Unicode look-around against `[\p{L}\p{N}]`
/// (not `\b`), so Cyrillic and other non-ASCII alphabets work as
/// expected — `то есть` won't match inside `кто есть` — AND pairs whose
/// `from` starts or ends with punctuation (`т.е.`, `e.g.`, `.com`,
/// `c#`, `#tag`) still match at real boundaries. `\b` would mis-anchor
/// those because ICU treats leading / trailing punctuation as non-word.
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
    /// pattern wraps the escaped `find` in a Unicode look-around —
    /// `(?<![\p{L}\p{N}]) … (?![\p{L}\p{N}])` — instead of `\b`. ICU's
    /// `\b` treats leading / trailing punctuation in `find` (`т.е.`,
    /// `e.g.`, `.com`, `c#`, `#tag`) as non-word, so a `\b` anchored
    /// against a punctuation edge either fails to match or matches
    /// inside a larger token. The look-around instead asserts only that
    /// the characters immediately outside the match are not
    /// letters/digits, which handles both alphabetic and
    /// punctuation-bounded `from` values. Mirrors
    /// `DictionaryHarvester.findInContext` so the module shares one
    /// boundary idiom. `find` is escaped, so dots, plus signs, brackets
    /// etc. are treated literally. The replacement template needs
    /// separate escaping because regex replacement honours `$0..$9` and
    /// `\$`.
    private static func replaceWordBoundary(in text: String, find: String, with replacement: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: find) + "(?![\\p{L}\\p{N}])"
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
