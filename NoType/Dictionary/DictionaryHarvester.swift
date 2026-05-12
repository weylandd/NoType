import Foundation

/// Pure-function dictionary candidate extractor. Replaces the old
/// post-session LLM extractor with a deterministic algorithm:
///
/// 1. Tokenize the final transcript (Unicode-aware word boundaries plus
///    the atypical-text binders `.`, `_`, `/`, `-`).
/// 2. For each token that looks proper-noun-ish (capitalized, mixed-case,
///    all-caps, or carrying an atypical binder), try increasing
///    multi-word spans (3 → 2 → 1 tokens) and check if the phrase
///    appears verbatim in the on-screen context (case-insensitive,
///    word-boundary).
/// 3. When a span matches context, save the context's casing (so we get
///    `NoType` even if the transcript said `notype`), consume the span's
///    tokens, and move on.
///
/// Honors ADR-016's "context-derived only" principle by construction: a
/// candidate is added iff it appears in BOTH the user's spoken text AND
/// the on-screen surroundings the model saw. No LLM round-trip, no
/// API cost, no noisy invented terms.
enum DictionaryHarvester {
    /// Hard cap on entries returned per session. Mirrors the LLM
    /// extractor's 5-per-call cap from ADR-016 — protects against a
    /// single noisy session flooding the dictionary.
    static let maxCandidates = 5

    /// Safety upper bound on candidate length. Also doubles as the
    /// length cap on user-typed entries in the Dictionary tab — protects
    /// the `User dictionary:` prompt section from bloat regardless of
    /// whether the entry came in via the harvester or the UI textfield.
    static let sanityMaxLength = 30

    /// Maximum token span for multi-word matching.
    static let maxSpan = 3

    /// Minimum length for a single-token candidate. Single-letter tokens
    /// like "I" or "A" technically pass shape but are never useful.
    static let minSingleTokenLength = 2

    /// Run the harvester. Returns canonical-cased candidates in
    /// transcript order, deduped case-insensitively against `existing`
    /// and against each other.
    static func harvest(
        transcript: String,
        context: String,
        existing: [String]
    ) -> [String] {
        guard !transcript.isEmpty, !context.isEmpty else { return [] }

        let tokens = tokenize(transcript)
        let existingLower = Set(existing.map { $0.lowercased() })
        var savedLower: Set<String> = []
        var out: [String] = []

        var i = 0
        while i < tokens.count && out.count < maxCandidates {
            var hit: (canonical: String, consume: Int)?
            // Longest-match priority — try 3, then 2, then 1.
            //
            // Shape filter is applied to the CANONICAL (context-cased)
            // form, not the transcript form. Reason: the transcription
            // engine often writes proper nouns lowercase (`anthropic`,
            // `noтайп`) when audio is unclear; the canonical form lives
            // on screen with proper casing (`Anthropic`, `NoType`).
            // Checking the canonical means we still save these — which
            // is the whole point of the harvester.
            for span in stride(from: maxSpan, through: 1, by: -1) {
                if i + span > tokens.count { continue }
                let phrase = Array(tokens[i..<(i + span)])
                if span == 1, phrase[0].count < minSingleTokenLength { continue }
                if let canonical = findInContext(phrase: phrase, context: context),
                   canonical.count <= sanityMaxLength,
                   passesShape(canonical) {
                    hit = (canonical, span)
                    break
                }
            }

            if let hit {
                let lower = hit.canonical.lowercased()
                if !existingLower.contains(lower), !savedLower.contains(lower) {
                    out.append(hit.canonical)
                    savedLower.insert(lower)
                }
                i += hit.consume
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: - Tokenization

    /// Split a string into tokens. Each token is a maximal run of
    /// letter / digit / `_` / `/` / `-`, optionally with internal `.`
    /// (period between two letter-or-digit chars — for `claude.md`,
    /// `react.dev`). A trailing period is dropped (sentence end).
    /// Tokens must contain at least one letter; pure-digit / pure-binder
    /// runs are discarded.
    static func tokenize(_ s: String) -> [String] {
        let chars = Array(s)
        var tokens: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if isLetter(c) || isDigit(c) || isBinder(c) {
                let start = i
                while i < chars.count {
                    let cur = chars[i]
                    if isLetter(cur) || isDigit(cur) || isBinder(cur) {
                        i += 1
                        continue
                    }
                    if cur == ".",
                       i + 1 < chars.count,
                       isLetter(chars[i + 1]) || isDigit(chars[i + 1]) {
                        i += 1
                        continue
                    }
                    break
                }
                let raw = String(chars[start..<i])
                // Filter out tokens that are only binders / digits.
                if raw.contains(where: { isLetter($0) }) {
                    tokens.append(raw)
                }
            } else {
                i += 1
            }
        }
        return tokens
    }

    private static func isLetter(_ c: Character) -> Bool { c.isLetter }
    private static func isDigit(_ c: Character) -> Bool { c.isNumber }
    private static func isBinder(_ c: Character) -> Bool {
        c == "_" || c == "/" || c == "-"
    }

    // MARK: - Shape filter

    /// True when the token looks proper-noun-ish — first-letter capital
    /// in any Unicode script, internal mixed-case (iOS, gRPC), all-caps
    /// (NASA), or carries an atypical-text binder (claude.md,
    /// generate_keys, bin/python).
    static func passesShape(_ token: String) -> Bool {
        guard token.contains(where: { $0.isLetter }) else { return false }

        // Atypical binders are inherently non-prose and worth saving.
        if token.contains(where: { $0 == "." || $0 == "_" || $0 == "/" || $0 == "-" }) {
            return true
        }

        // Any uppercase letter present in any position → proper-noun-ish.
        // Covers "Anthropic" (first-letter cap), "iOS" / "gRPC" (internal
        // cap), "NASA" (all-caps).
        return token.contains { $0.isLetter && $0.isUppercase }
    }

    // MARK: - Context lookup

    /// Search `context` for `phrase` (a list of tokens joined with
    /// flexible whitespace), case-insensitive, with word-boundary at
    /// both ends. Returns the matched span using the context's actual
    /// casing — so a transcript token `notype` matched against
    /// `NoType` in context yields `NoType` as the canonical form.
    ///
    /// Word-boundary semantics use look-around against
    /// `[\p{L}\p{N}]` rather than `\b`: the binder chars in our tokens
    /// (`/`, `_`, `-`) are non-word for ICU `\b`, which would fail to
    /// match `bin/` followed by whitespace (`\b` requires word/non-word
    /// transition, two non-word chars in a row → no boundary).
    static func findInContext(phrase: [String], context: String) -> String? {
        guard !phrase.isEmpty else { return nil }
        let escaped = phrase.map { NSRegularExpression.escapedPattern(for: $0) }
        let inner = escaped.joined(separator: "\\s+")
        let pattern = "(?<![\\p{L}\\p{N}])(\(inner))(?![\\p{L}\\p{N}])"

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }

        let range = NSRange(context.startIndex..., in: context)
        guard let match = regex.firstMatch(in: context, options: [], range: range),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: context) else {
            return nil
        }

        // Normalize internal whitespace to single space — context lines
        // are often indented with newlines + multiple spaces between
        // adjacent words. We want "Вася Пупкин", not "Вася\n  Пупкин".
        let raw = String(context[captured])
        let normalized = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized
    }
}
