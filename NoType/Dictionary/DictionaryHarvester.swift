import Foundation
import NaturalLanguage

/// Pure-function dictionary candidate extractor. Replaces the old
/// post-session LLM extractor with a deterministic algorithm:
///
/// 1. Tokenize the final transcript (Unicode-aware word boundaries plus
///    the binders `_`, `/`, `-`), tracking which tokens stand at a
///    sentence-start position so we can distinguish real proper nouns
///    from sentence-start chrome words.
/// 2. For each token position, try increasing multi-word spans
///    (3 → 2 → 1 tokens) and check if the phrase appears verbatim in
///    the on-screen context (case-insensitive, word-boundary).
/// 3. When a span matches, evaluate the canonical (context's casing)
///    against two shape tiers:
///    - **Strict**: internal uppercase, digit, special binder, or
///      dot+long. Saves regardless of sentence position.
///    - **First-cap mid-sentence**: canonical starts with capital
///      letter, has only letters + spaces, AND lives at non-sentence-
///      start position in EITHER transcript or context. Saves brands
///      like `Anthropic` / `Slack` / `Apple` mentioned mid-flow while
///      still rejecting sentence-start chrome like `Вот` / `Так`.
/// 4. Consume the span's tokens, dedup case-insensitively, move on.
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

    /// Minimum length for a single-token candidate. Filters very short
    /// acronyms like `UI` (2 chars) which technically pass shape via
    /// the internal-cap rule but are too generic to be useful entries.
    static let minSingleTokenLength = 3

    /// Minimum canonical length for the first-cap-mid-sentence tier.
    /// Common short words like `Так`, `Вот`, `Для`, `Auto`, `Tool`
    /// were leaking via the first-cap tier — their canonical happened
    /// to appear capitalized somewhere in the noisy full-screen AX
    /// dump (notifications, menu items, button labels). Setting the
    /// minimum at 5 chars filters those out while keeping legitimate
    /// brand names: `Slack` (5), `Apple` (5), `Anthropic` (9),
    /// `Vasya` (5), `Microsoft` (9). Strict tier still caches shorter
    /// tokens (`iOS` 3, `gRPC` 4, `NASA` 4) via internal-cap / digit
    /// signals.
    static let firstCapTierMinLength = 5

    /// Languages where ALL nouns are capitalized, not just proper
    /// nouns. The first-cap-mid-sentence tier would over-collect
    /// common nouns (`Haus`, `Auto`, `Termin`) as dictionary entries,
    /// flooding the user's word list. For these languages we skip the
    /// first-cap tier and rely on the strict tier (internal cap,
    /// digit, special binder, dot+long) to catch real proper nouns.
    ///
    /// Currently: German is the canonical case. Add more cases as
    /// they're reported — Luxembourgish is similar but not in
    /// `NLLanguage`'s built-in set; orthographic German covers most
    /// of it via dominant-language fallback.
    static let nounCapitalizingLanguages: Set<NLLanguage> = [.german]

    /// Detect whether the dictation transcript is in a
    /// noun-capitalizing language using Apple's `NLLanguageRecognizer`.
    /// Pure statistical classifier — fast on the short transcripts we
    /// pass it. Returns `false` for empty / undetermined results so we
    /// err toward the more permissive first-cap tier (admit
    /// `Anthropic`/`Slack` rather than reject them on uncertainty).
    ///
    /// We classify the **transcript**, not the context: the user's
    /// speech determines which capitalization conventions apply. A
    /// German speaker dictating into an English app should still get
    /// noun-cap handling; an English speaker dictating into a German
    /// app shouldn't. Choosing transcript-as-language-source is the
    /// load-bearing call here.
    ///
    /// Why a statistical recognizer over character heuristics
    /// (`ß`-detection): German texts routinely lack `ß` entirely
    /// (Swiss German always; modern Germany after the 1996 reform
    /// often), and `ä`/`ö`/`ü` are shared with Swedish/Finnish/
    /// Turkish/Estonian. NLLanguageRecognizer uses word frequency
    /// + grammatical markers (Das/Der/Die, capitalization rate) and
    /// generalises across the long tail of German-flavoured input.
    static func isNounCapitalizingLanguage(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return false }
        return nounCapitalizingLanguages.contains(lang)
    }

    /// Token + sentence-start flag. Exposed for tests so they can pin
    /// the sentence-start classifier independently of the harvest loop.
    struct Token: Equatable, Sendable {
        let text: String
        /// True when this token begins a fresh "sentence" in the source
        /// string. We consider `.!?…` (plus their full-width / CJK
        /// variants), newline, AND `:` / `;` as boundary markers. The
        /// last two cover the UI-context pattern `Label: Value` — without
        /// them, `Value` would look mid-sentence and the harvester would
        /// over-collect single-cap labels.
        let isSentenceStart: Bool
    }

    /// Run the harvester. Returns canonical phrases (in **transcript**
    /// casing) to save or refresh in the dictionary.
    ///
    /// Algorithm overview (driven by transcript only — context is used
    /// solely to verify each candidate phrase actually appears on
    /// screen, never to promote casing or invent candidates):
    ///
    /// 1. Split the transcript into sentences via `NLTokenizer(.sentence)`.
    /// 2. Word-tokenize each sentence; first word marked sentence-start.
    /// 3. Detect TRIGGERS — tokens passing the transcript shape filter:
    ///    internal uppercase, special binder, long-with-dot, OR
    ///    first-letter cap with length ≥ `firstCapTierMinLength` and
    ///    NOT at sentence-start. Pure digits (`10`, `2024`) are NOT
    ///    triggers on their own.
    /// 4. For each trigger, build candidate phrases over a ±2 word
    ///    window WITHIN THE SAME SENTENCE. Sort longest-first.
    /// 5. For each candidate (longest first):
    ///    - Boundary filter: first AND last tokens must look "non-prose"
    ///      (have uppercase letter, digit, special binder, or long-dot).
    ///      This is what rejects `на Actions artifacts` and
    ///      `Actions artifacts` while keeping `iPhone 10` and
    ///      `GitHub Actions`.
    ///    - Minimum length for 1-grams.
    ///    - Context match (verbatim, case-insensitive, word-boundary).
    ///    - Skip if substring of any phrase already saved THIS session.
    ///    - Skip if **strictly** contained in an `existing` entry
    ///      (existing is more informative; exact matches PASS to the
    ///      caller as a "refresh me" signal).
    ///    - Save (transcript casing). First match wins per trigger.
    ///
    /// `nounCapitalizingLanguage` defaults to `nil`, which makes the
    /// harvester auto-detect via `isNounCapitalizingLanguage(transcript)`.
    /// When true (German today), the first-cap-tier in `isTrigger`
    /// is disabled — strict triggers (internal cap / digit / binder /
    /// long-dot) still fire so `iPhone 10` etc. still save.
    static func harvest(
        transcript: String,
        context: String,
        existing: [String],
        nounCapitalizingLanguage: Bool? = nil
    ) -> [String] {
        guard !transcript.isEmpty, !context.isEmpty else { return [] }

        let nounCap = nounCapitalizingLanguage ?? isNounCapitalizingLanguage(transcript)
        let existingSequences = existing.map { entry in
            entry.lowercased().split(separator: " ").map(String.init)
        }
        let sentences = sentenceTokenize(transcript)

        var saved: [String] = []
        var savedSequences: [[String]] = []  // lowercase tokens, for substring dedup

        for sentenceTokens in sentences {
            if saved.count >= maxCandidates { break }

            for triggerIdx in sentenceTokens.indices {
                if saved.count >= maxCandidates { break }
                guard isTrigger(sentenceTokens[triggerIdx], nounCap: nounCap) else { continue }

                // ±2 window around trigger, clamped to sentence bounds.
                let leftWin = max(0, triggerIdx - 2)
                let rightWin = min(sentenceTokens.count - 1, triggerIdx + 2)

                // All sub-phrases [a..b] containing the trigger position.
                // Sort longest-first; ties keep stable order so left-anchored
                // phrases tend to come before right-anchored at same length.
                var triggerCandidates: [[String]] = []
                for a in leftWin...triggerIdx {
                    for b in triggerIdx...rightWin {
                        triggerCandidates.append((a...b).map { sentenceTokens[$0].text })
                    }
                }
                triggerCandidates.sort { lhs, rhs in lhs.count > rhs.count }

                // First match wins — per user spec.
                for tokens in triggerCandidates {
                    if processCandidate(
                        tokens: tokens,
                        context: context,
                        existingSequences: existingSequences,
                        savedSequences: &savedSequences,
                        saved: &saved
                    ) {
                        break
                    }
                }
            }
        }

        return saved
    }

    /// Returns `true` when this candidate has been definitively handled
    /// (saved or skipped because it duplicates / is covered by an
    /// earlier phrase). Returns `false` when the candidate was rejected
    /// by a per-candidate filter (boundary fail, length, context miss);
    /// the caller should try the next, shorter candidate.
    private static func processCandidate(
        tokens: [String],
        context: String,
        existingSequences: [[String]],
        savedSequences: inout [[String]],
        saved: inout [String]
    ) -> Bool {
        guard let first = tokens.first, let last = tokens.last else { return false }

        // Boundary filter: phrase endpoints must look non-prose. Filters
        // `на Actions artifacts` (first `на` lowercase prose),
        // `Actions artifacts` (last `artifacts` lowercase prose).
        guard hasInterestingSignal(first), hasInterestingSignal(last) else { return false }

        // Single-token minimum length (filters `UI` and other 2-char generics).
        if tokens.count == 1, tokens[0].count < minSingleTokenLength { return false }

        // Sanity cap on phrase length.
        let joined = tokens.joined(separator: " ")
        if joined.count > sanityMaxLength { return false }

        // Context verbatim match.
        guard findInContext(phrase: tokens, context: context) != nil else { return false }

        let candidateSeq = tokens.map { $0.lowercased() }

        // Substring dedup against saves already made this session.
        // Stops descending to shorter phrases — they'd be even more
        // contained by the same saved entry.
        for savedSeq in savedSequences {
            if isContiguousSubsequence(candidateSeq, of: savedSeq) {
                return true
            }
        }

        // Strict-superset dedup against existing dictionary entries.
        // Skip when an existing entry is a LONGER phrase that contains
        // this candidate — existing already covers it more informatively.
        // EXACT matches pass through: caller refreshes the existing
        // entry's timestamp so the FIFO trim sees it as fresh.
        for existingSeq in existingSequences {
            if isContiguousSubsequence(candidateSeq, of: existingSeq),
               candidateSeq != existingSeq {
                return true
            }
        }

        saved.append(joined)
        savedSequences.append(candidateSeq)
        return true
    }

    /// True when this transcript token can SEED a candidate phrase.
    /// Stricter than `hasInterestingSignal` (the boundary check): pure
    /// digit tokens (`10`, `2024`) are NOT triggers on their own — the
    /// user specifically excluded those. First-cap-plain tokens (`Apple`,
    /// `Anthropic`) only trigger when their length passes the tier
    /// threshold AND they aren't at sentence-start.
    static func isTrigger(_ token: Token, nounCap: Bool) -> Bool {
        // Require at least one letter — filters bare `10`, `2024`.
        guard token.text.contains(where: { $0.isLetter }) else { return false }

        // Strict tier: internal cap, digit-with-letter, special binder,
        // long-with-dot.
        if passesShape(token.text) { return true }

        // Noun-capitalizing language path skips the first-cap tier
        // entirely (German etc.).
        guard !nounCap else { return false }

        // First-cap-plain tier: length floor + not at sentence-start.
        if isFirstCapPlainShape(token.text),
           token.text.count >= firstCapTierMinLength,
           !token.isSentenceStart {
            return true
        }
        return false
    }

    /// True when the token looks non-prose enough to anchor a phrase
    /// boundary. Looser than `isTrigger` — pure-digit tokens (`10`,
    /// `2024`) and short first-caps (`Pro`, `Inc`) also pass, so
    /// `iPhone 10` and `Anthropic Inc` can be saved as multi-word
    /// phrases. Pure-prose tokens (`на`, `artifacts`, `сохраняется`)
    /// fail.
    static func hasInterestingSignal(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber }) { return true }
        if token.contains(where: { $0.isLetter && $0.isUppercase }) { return true }
        if token.contains(where: { "/_*#$".contains($0) }) { return true }
        if token.contains(".") && token.count >= 6 { return true }
        return false
    }

    /// Per-sentence word tokenization. Uses `NLTokenizer(unit: .sentence)`
    /// to find sentence ranges (which handles abbreviations like `т.е.`,
    /// `etc.` smarter than my own punctuation heuristic), then re-runs
    /// the word `tokenize(_:)` on each sentence's substring. The first
    /// word of each sentence is marked sentence-start; the rest are not.
    static func sentenceTokenize(_ s: String) -> [[Token]] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = s
        var sentences: [[Token]] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let sentenceText = String(s[range])
            let words = tokenize(sentenceText)
            let normalized = words.enumerated().map { idx, tok in
                Token(text: tok.text, isSentenceStart: idx == 0)
            }
            if !normalized.isEmpty { sentences.append(normalized) }
            return true
        }
        return sentences
    }

    /// True when `candidate` appears as a contiguous case-folded
    /// sub-sequence within `sequence`. Used for substring dedup
    /// against this session's saves and against existing dictionary
    /// entries.
    static func isContiguousSubsequence(_ candidate: [String], of sequence: [String]) -> Bool {
        guard candidate.count <= sequence.count else { return false }
        if candidate.isEmpty { return true }
        for start in 0...(sequence.count - candidate.count) {
            if Array(sequence[start..<(start + candidate.count)]) == candidate {
                return true
            }
        }
        return false
    }

    /// Filter for the LAST token of a multi-word canonical span.
    /// Returns true when the token carries its own shape signal — a
    /// first-letter capital, a digit, a special binder, or an internal
    /// period. Lowercase prose endings (`сохраняется`, `working`,
    /// `tomorrow`) fail this check, so multi-word spans that bolt a
    /// verb onto a brand mention fall back to a shorter, more reusable
    /// canonical (`iPhone 10` instead of `iPhone 10 сохраняется`).
    static func hasMultiWordTailSignal(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if let first = token.first, first.isLetter, first.isUppercase {
            return true
        }
        if token.contains(where: { $0.isNumber }) {
            return true
        }
        if token.contains(where: { "/_*#$.".contains($0) }) {
            return true
        }
        return false
    }

    /// Decide whether a candidate should be saved. Two tiers:
    ///
    /// **Strict** (`passesShape`) — saves regardless of where the
    /// candidate sits in transcript/context. Catches truly "weird"
    /// tokens: internal uppercase, digits, special binders, long
    /// dot-bearing identifiers. Applies in every language.
    ///
    /// **First-cap mid-sentence** — saves first-cap-plain canonicals
    /// (`Anthropic`, `Slack`, `Apple`, `Apple news`) when:
    /// 1. The transcript head token is **NOT** at sentence-start. If
    ///    the user dictated this word at the start of a sentence,
    ///    treat it as chrome (even if context happens to show it
    ///    mid-sentence somewhere in the noisy full-screen AX dump).
    /// 2. Canonical length ≥ `firstCapTierMinLength` (5). Filters
    ///    short common words like `Так`, `Вот`, `Для`, `Auto`, `Tool`
    ///    that pollute the dictionary on every session.
    ///
    /// The earlier OR-rule "mid-sentence in EITHER transcript or
    /// context" was too permissive in practice — the full-screen AX
    /// tree picks up so much text from notifications, menus, and
    /// background apps that virtually every short capitalized word
    /// has a mid-sentence occurrence somewhere. Real-world testing
    /// surfaced this as recurring noise; the tier now relies on the
    /// transcript-position signal alone.
    ///
    /// **Skipped entirely for noun-capitalizing languages** (German
    /// today). German capitalizes ALL nouns, so every `Haus`, `Auto`,
    /// `Termin` mid-sentence would surface — pure noise. German users
    /// fall back to strict tier alone; they lose unmarked brand
    /// names like `Anthropic`/`Slack` as auto-entries but keep
    /// `iPhone`/`h264`/`Apple iPhone` via strict tier and can always
    /// add brands manually through the textfield.
    static func shouldSave(
        transcriptHead: Token,
        canonical: String,
        nounCapitalizingLanguage: Bool = false
    ) -> Bool {
        if passesShape(canonical) {
            return true
        }
        guard !nounCapitalizingLanguage else { return false }
        guard canonical.count >= firstCapTierMinLength else { return false }
        guard isFirstCapPlainShape(canonical) else { return false }
        guard !transcriptHead.isSentenceStart else { return false }
        return true
    }

    // MARK: - Tokenization

    /// Split a string into tokens with sentence-start flags. Each token
    /// is a maximal run of letter / digit / `_` / `/` / `-`, optionally
    /// with internal `.` (between two letter-or-digit chars — for
    /// `claude.md`, `react.dev`). A trailing period is dropped.
    /// Pure-binder runs (`___`, `----`) are discarded; pure-digit runs
    /// (`10`, `2024`) are KEPT so multi-word phrases like `iPhone 10`
    /// can be matched as a 2-span.
    ///
    /// Sentence-start tracking: a token starts a new "sentence" if it
    /// follows `.!?…` (plus full-width / CJK variants), newline, or
    /// `:` / `;` (the colon/semicolon rule covers UI-context patterns
    /// like `Label: Value` — without it, every Value would look like
    /// mid-sentence chrome). Implicit BOS counts as sentence-start.
    static func tokenize(_ s: String) -> [Token] {
        let chars = Array(s)
        var tokens: [Token] = []
        var i = 0
        var nextIsSentenceStart = true

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
                let hasLetter = raw.contains(where: { isLetter($0) })
                let hasDigit  = raw.contains(where: { isDigit($0) })
                if hasLetter || hasDigit {
                    tokens.append(Token(text: raw, isSentenceStart: nextIsSentenceStart))
                }
                nextIsSentenceStart = false
            } else {
                if resetsSentenceFlag(c) {
                    nextIsSentenceStart = true
                }
                // Other chars (whitespace, comma, quotes, Spanish ¿¡,
                // brackets): keep the flag as-is. So `¿Anthropic` after
                // a previous sentence-ender still marks Anthropic as
                // sentence-start; `Header: Anthropic` flips to sentence-
                // start on the colon.
                i += 1
            }
        }
        return tokens
    }

    /// Plain-text version of `tokenize` for callers that don't need
    /// sentence-start info (older tests, ad-hoc inspection). Keeps the
    /// internal logic in one place.
    static func tokenizeText(_ s: String) -> [String] {
        return tokenize(s).map { $0.text }
    }

    private static func isLetter(_ c: Character) -> Bool { c.isLetter }
    private static func isDigit(_ c: Character) -> Bool { c.isNumber }
    private static func isBinder(_ c: Character) -> Bool {
        c == "_" || c == "/" || c == "-"
    }

    /// True when this character should mark the NEXT token as
    /// sentence-start. Includes ASCII `.!?`, the ellipsis `…`, CJK
    /// fullwidth `。！？`, the colon `:`/`;` (UI label boundary), and
    /// any Unicode newline. Spanish openers `¿¡` are NOT here — they
    /// don't reset by themselves; they pass through and the prior
    /// terminator (or BOS) keeps the next-token-is-sentence-start state.
    private static func resetsSentenceFlag(_ c: Character) -> Bool {
        if c.isNewline { return true }
        if c == "." || c == "!" || c == "?" { return true }
        if c == "\u{2026}" { return true }      // … (ellipsis)
        if c == "\u{3002}" { return true }      // 。 (fullwidth CJK period)
        if c == "\u{FF01}" { return true }      // ！ (fullwidth exclam)
        if c == "\u{FF1F}" { return true }      // ？ (fullwidth question)
        if c == ":" || c == ";" { return true } // UI label boundary
        return false
    }

    // MARK: - Shape filter (strict tier)

    /// Strict shape filter — saves regardless of sentence position.
    /// Applied to the CANONICAL (context-cased, multi-word joined)
    /// form. Four independent rules; any one passes:
    ///
    /// (a) **Internal uppercase** — uppercase letter at any position
    ///     **except 0** of the joined string. Catches `iPhone` (P at 1),
    ///     `gRPC` (R at 1), `NASA` (A/S/A at 1+), multi-word brand
    ///     mentions where the second word's first cap is internal:
    ///     `Apple iPhone` (P at 6), `Anthropic Inc` (I at 10),
    ///     `Вася Пупкин` (П at 5).
    ///
    /// (b) **Contains digit** — code / version / model shape. Catches
    ///     `h264`, `mp4`, `version1`, `iPhone 10`, `Year 2024`.
    ///
    /// (c) **Special binder** — `/`, `_`, `*`, `#`, `$`. Strong
    ///     non-prose signal (paths, identifiers, glob, handles).
    ///     Hyphen `-` and period `.` are NOT in this set — they appear
    ///     in regular Russian pronouns (`что-то`, `какой-то`) and
    ///     abbreviations (`т.е.`).
    ///
    /// (d) **Dot + length ≥ 6 chars** — filename / domain-like tokens
    ///     (`claude.md`, `react.dev`, `app.notype`). Filters out short
    ///     abbreviations.
    ///
    /// Rejects pure-prose lowercase, pure-digit/binder runs, single
    /// first-cap-only tokens (`Anthropic`, `Вот`), and hyphen-only
    /// words (`что-то`). Those can still ride through the first-cap-
    /// mid-sentence tier (see `shouldSave`).
    static func passesShape(_ token: String) -> Bool {
        let chars = Array(token)
        guard chars.contains(where: { $0.isLetter }) else { return false }

        // (a) Internal uppercase — uppercase letter at index ≥ 1.
        if chars.dropFirst().contains(where: { $0.isLetter && $0.isUppercase }) {
            return true
        }

        // (b) Contains digit.
        if chars.contains(where: { $0.isNumber }) {
            return true
        }

        // (c) Special non-prose binders.
        if chars.contains(where: { "/_*#$".contains($0) }) {
            return true
        }

        // (d) Dot AND length ≥ 6.
        if chars.contains(".") && chars.count >= 6 {
            return true
        }

        return false
    }

    /// True when the canonical looks like a "Title-case word" or
    /// "Title-case + lowercase filler" multi-word phrase — i.e. starts
    /// with a capital letter and contains only letters + spaces (no
    /// digits, no binders, no special chars). This is the residual
    /// shape that the strict filter rejects but that legitimately
    /// describes proper nouns like `Anthropic`, `Slack`, `Apple`,
    /// `Anthropic news`, `Slack команде`.
    ///
    /// Combined with the sentence-start check in `shouldSave`, this
    /// admits brand mentions in flowing prose while still rejecting
    /// sentence-start chrome (`Вот`, `Так`, `Для этого`).
    static func isFirstCapPlainShape(_ canonical: String) -> Bool {
        guard let first = canonical.first, first.isLetter, first.isUppercase else {
            return false
        }
        for c in canonical {
            if c.isLetter || c.isWhitespace { continue }
            return false
        }
        return true
    }

    // MARK: - Context lookup

    /// Result of `findInContext`. The canonical is the on-screen
    /// casing; `isAtSentenceStart` reports whether that match sits at
    /// a fresh sentence boundary in the context string.
    struct ContextMatch: Equatable, Sendable {
        let canonical: String
        let isAtSentenceStart: Bool
    }

    /// Search `context` for `phrase` (a list of tokens joined with
    /// flexible whitespace), case-insensitive, with word-boundary at
    /// both ends. Returns the matched span using the context's actual
    /// casing — so a transcript token `notype` matched against
    /// `NoType` in context yields `NoType` as the canonical form.
    ///
    /// Also reports whether the match position is at sentence-start in
    /// the context — used by `shouldSave` to admit first-cap-plain
    /// candidates that live mid-sentence somewhere.
    ///
    /// Word-boundary semantics use look-around against
    /// `[\p{L}\p{N}]` rather than `\b`: the binder chars in our tokens
    /// (`/`, `_`, `-`) are non-word for ICU `\b`, which would fail to
    /// match `bin/` followed by whitespace.
    static func findInContext(phrase: [String], context: String) -> ContextMatch? {
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

        let isAtStart = isAtSentenceStart(in: context, before: captured.lowerBound)
        return ContextMatch(canonical: normalized, isAtSentenceStart: isAtStart)
    }

    /// True when the character position in `text` sits at a fresh
    /// sentence boundary. Walks backward through whitespace; the first
    /// non-whitespace char decides:
    ///   - newline / start-of-string / sentence-ender (`.!?…。！？:;`)
    ///     → sentence-start.
    ///   - letter / digit → mid-sentence (preceded by another word).
    ///   - other punctuation (commas, parens, quotes, Spanish `¿¡`):
    ///     skip and keep walking — these don't define the boundary
    ///     either way; we want the next "real" signal.
    static func isAtSentenceStart(in text: String, before position: String.Index) -> Bool {
        var idx = position
        while idx > text.startIndex {
            idx = text.index(before: idx)
            let c = text[idx]
            if c.isNewline { return true }
            if c.isWhitespace { continue }
            if resetsSentenceFlag(c) { return true }
            if c.isLetter || c.isNumber { return false }
            // Other punctuation (commas, brackets, Spanish ¿¡): skip,
            // keep walking until we find a definitive boundary marker
            // or hit the start of the string.
            continue
        }
        return true
    }
}
