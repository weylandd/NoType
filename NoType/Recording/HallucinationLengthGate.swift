import Foundation

/// Post-response length-proportional sanity check for Gemini
/// transcripts. Drops the transcript (returns `""`) when its word
/// count AND character count both exceed what's physically plausible
/// for the audio duration.
///
/// **Why this exists.** On short, low-information audio (BT-HFP
/// mic + a single word like "проверка"), Gemini 3.1 Flash-Lite
/// sometimes ignores the system prompt's "if unintelligible, output
/// empty string" clause and emits a conversational fallback like
/// `"Can you help me with this?"`. The fallback is wildly
/// disproportionate to the input: 6 words / 26 chars from ~1 s of
/// audio (≈6 wps / 26 cps), well past sustained human dictation
/// rates. The system prompt is already strict; this gate is the
/// belt to the prompt's braces — pure client-side, no extra Gemini
/// round-trip.
///
/// **AND mode by design.** Both the word ceiling AND the char
/// ceiling must be exceeded for the gate to trip. This is safer for
/// false positives than OR mode — a borderline legitimate
/// dense-Russian utterance ("Привет, как дела?" at 1.07 s ≈ 3 words
/// / 16 chars) trips neither dimension and survives, while a
/// 6-word / 26-char hallucination on 1 s trips both.
///
/// **What it catches vs. doesn't.** Catches over-production
/// hallucinations on short audio (Gemini emits more words than the
/// audio could fit). Does NOT catch silence-class hallucinations
/// where the model returns a normal-rate phrase (e.g. "Hello, how
/// are you?" — 5 words / 19 chars on 2 s of silence = 2.5 wps,
/// well under the ceiling). Silence-class needs a different filter
/// (audio-energy gate, separate work).
///
/// Pure function; deterministic; no I/O.
enum HallucinationLengthGate {

    /// Sustained word-rate ceiling. 4 wps ≈ 240 wpm — above
    /// "very fast" conversational rate (200 wpm) and just under
    /// auctioneer / fast-rap territory (250+ wpm). Real dictation
    /// runs at 2–3 wps; existing eval fixtures
    /// (`long_monologue_en` ≈ 2.8 wps, `multi_sentence_en` ≈ 2.4 wps)
    /// have plenty of headroom.
    static let maxWordsPerSecond: Double = 4.0

    /// Character-rate ceiling. 18 cps gives headroom for Russian
    /// (longer average word length than English) and Gemini's
    /// punctuation variability. `greeting_ru` ("Привет, как дела?",
    /// 17 chars at 1.07 s ≈ 15.89 cps) passes comfortably.
    static let maxCharsPerSecond: Double = 18.0

    /// Hard floor — even on very short audio (<1 s) we always
    /// allow up to 4 words / 18 chars. Without this a 0.5 s chunk
    /// would get a 2-word / 9-char ceiling and trip on legitimate
    /// short utterances.
    static let floorWords: Int = 4
    static let floorChars: Int = 18

    /// Returns the original transcript, or `""` if the AND-gate
    /// trips. Whitespace-only inputs pass through unchanged.
    static func apply(to transcript: String, durationSeconds: TimeInterval) -> String {
        shouldDropAsHallucination(transcript: transcript, durationSeconds: durationSeconds)
            ? ""
            : transcript
    }

    /// Pure decision exposed for tests. Returns `true` iff both
    /// dimensions (words and chars) exceed the per-duration ceiling.
    ///
    /// - `durationSeconds <= 0` short-circuits to `false` — we can't
    ///   compute a ratio without a positive duration, and the
    ///   `RecordingSession` already filters sub-150 ms chunks at the
    ///   PCM-count gate before this can be reached.
    /// - Empty / whitespace-only transcripts also return `false` —
    ///   nothing to drop. (The intended drop output is `""`; the
    ///   gate doesn't pile-on already-empty responses.)
    static func shouldDropAsHallucination(
        transcript: String,
        durationSeconds: TimeInterval
    ) -> Bool {
        guard durationSeconds > 0 else { return false }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        let charCount = trimmed.count

        let wordCeiling = max(floorWords, Int(ceil(durationSeconds * maxWordsPerSecond)))
        let charCeiling = max(floorChars, Int(ceil(durationSeconds * maxCharsPerSecond)))

        return wordCount > wordCeiling && charCount > charCeiling
    }
}
