import XCTest
@testable import NoType

/// Pins `HallucinationLengthGate` — the post-Gemini length-proportional
/// gate that drops conversational-fallback hallucinations on short
/// low-information audio. Threshold rationale + fixture matrix live in
/// the gate's doc-comment; this file pins the decisions against
/// representative transcripts.
final class HallucinationLengthGateTests: XCTestCase {

    // MARK: - Real production hallucinations (must trip)

    func test_drops_canYouHelpMe_at1s() {
        // The reported incident: 1.0 s of "проверка" through BT-HFP
        // came back as "Can you help me with this?" — 6 words, 26
        // chars. AND gate trips on both dimensions.
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Can you help me with this?",
            durationSeconds: 1.0
        )
        XCTAssertTrue(dropped, "1 s + 6w/26c must drop")
    }

    func test_drops_canYouHelpMe_at_slightlyShorter() {
        // Robustness: same hallucination on a 0.85 s chunk (audio
        // duration jitter from VAD pre-roll / trailing pause).
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Can you help me with this?",
            durationSeconds: 0.85
        )
        XCTAssertTrue(dropped, "0.85 s + 6w/26c must drop")
    }

    // MARK: - Existing legitimate fixtures (must pass)

    func test_passes_greetingRu_at1s07() {
        // `NoTypeTests/Fixtures/Audio/greeting_ru.m4a` — 1.07 s,
        // "Привет, как дела?" → 3 words / 16 chars.
        // Word ceiling at 1.07 s: max(4, ceil(1.07 * 4)) = 5
        // Char ceiling: max(18, ceil(1.07 * 18)) = 20
        // 3 ≤ 5, AND-gate falls before char check ever matters.
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Привет, как дела?",
            durationSeconds: 1.07
        )
        XCTAssertFalse(dropped, "greeting_ru must pass — 3w/16c is well under the per-second ceiling")
    }

    func test_passes_multiSentenceEN_at10s() {
        // 24 words / ~130 chars at 10 s — well within 40 word / 180
        // char ceiling.
        let transcript = "I just finished reviewing the document. The structure looks solid, but a few sections need rewriting. I want to focus on the introduction first."
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: transcript,
            durationSeconds: 10.0
        )
        XCTAssertFalse(dropped, "multi_sentence_en (~2.4 wps) must pass")
    }

    func test_passes_longMonologueEN_at30s() {
        // 85+ words / ~550 chars at 30 s — 2.8 wps / ~18 cps,
        // right at the char ceiling but under word ceiling.
        // AND-gate requires both to fail; words pass → drop=false.
        let transcript = String(repeating: "word ", count: 85) // 85 "word" + spaces ≈ 425 chars
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: transcript,
            durationSeconds: 30.0
        )
        XCTAssertFalse(dropped, "long_monologue_en class must pass")
    }

    // MARK: - Out-of-scope sub-classes (must pass — by design)

    func test_passes_silenceClassHallucination() {
        // `silence_only.m4a` → "Hello, how are you?" (4 words by
        // whitespace-split, 19 chars) on 2.0 s of silence. ~2 wps
        // / 9.5 cps — normal dictation rate, NOT a length-
        // proportional hallucination.
        // Different sub-class needs a different filter; this gate
        // intentionally lets it through (documented in gate's
        // doc-comment).
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Hello, how are you?",
            durationSeconds: 2.0
        )
        XCTAssertFalse(dropped, "silence-class hallucination intentionally not caught by this gate")
    }

    // MARK: - AND-mode behaviour

    func test_andMode_passesWhenOnlyWordsExceed() {
        // 8 single-letter "words" on 1 s — word gate would fire
        // (8 > 4) but char count (15) is below char ceiling (18).
        // AND-mode requires both → passes.
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "a b c d e f g h",
            durationSeconds: 1.0
        )
        XCTAssertFalse(dropped, "AND-mode: word-only excess must NOT trip")
    }

    func test_andMode_passesWhenOnlyCharsExceed() {
        // Three long made-up words on 1 s — char count (35) exceeds
        // 18 but word count (3) is at floor. AND-mode → passes.
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "antidisestablishmentarianism word again",
            durationSeconds: 1.0
        )
        XCTAssertFalse(dropped, "AND-mode: char-only excess must NOT trip")
    }

    func test_andMode_tripsWhenBothExceed() {
        // 6 words / 26 chars on 1 s — both ceilings exceeded.
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "one two three four five six!",
            durationSeconds: 1.0
        )
        XCTAssertTrue(dropped, "AND-mode: both-exceed must trip")
    }

    // MARK: - Floor behaviour

    func test_floor_appliesAtVeryShortDuration() {
        // 0.4 s linear ceiling = 1.6 word / 7.2 char — without the
        // floor, a single short word would trip. With floor 4w/18c:
        // "проверка" (1 word, 8 chars) → 1 ≤ 4 → passes.
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "проверка",
            durationSeconds: 0.4
        )
        XCTAssertFalse(dropped, "floor must keep single short words alive at sub-1s")
    }

    func test_floor_doesNotMaskClearHallucination() {
        // Even at very short duration, a clearly disproportionate
        // output trips (the floor is 4w/18c, not infinity).
        let dropped = HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Can you please help me with this important question?",
            durationSeconds: 0.5
        )
        XCTAssertTrue(dropped, "floor is bounded — long output on 0.5 s must trip")
    }

    // MARK: - Edge cases

    func test_emptyTranscript_passes() {
        XCTAssertFalse(HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "",
            durationSeconds: 1.0
        ))
    }

    func test_whitespaceOnlyTranscript_passes() {
        XCTAssertFalse(HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "   \n\t  ",
            durationSeconds: 1.0
        ))
    }

    func test_zeroDuration_passes() {
        // No duration → can't compute ratio. Defensive: pass through.
        XCTAssertFalse(HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Can you help me with this?",
            durationSeconds: 0.0
        ))
    }

    func test_negativeDuration_passes() {
        XCTAssertFalse(HallucinationLengthGate.shouldDropAsHallucination(
            transcript: "Can you help me with this?",
            durationSeconds: -1.0
        ))
    }

    // MARK: - apply() returns empty on drop, original on pass

    func test_apply_returnsEmptyOnDrop() {
        let out = HallucinationLengthGate.apply(
            to: "Can you help me with this?",
            durationSeconds: 1.0
        )
        XCTAssertEqual(out, "")
    }

    func test_apply_returnsOriginalOnPass() {
        let out = HallucinationLengthGate.apply(
            to: "Привет, как дела?",
            durationSeconds: 1.07
        )
        XCTAssertEqual(out, "Привет, как дела?")
    }
}
