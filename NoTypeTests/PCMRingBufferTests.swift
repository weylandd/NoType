import XCTest
@testable import NoType

/// Pins `PCMRingBuffer`'s semantics — wrap-around correctness, absolute
/// indexing across `discard`, overflow handling, and the recentSamples
/// convenience used by the spectrum meter.
final class PCMRingBufferTests: XCTestCase {

    /// Convenience to build a deterministic float sequence: index i → Float(i + base).
    private func seq(_ start: Int, _ count: Int) -> [Float] {
        (0..<count).map { Float(start + $0) }
    }

    // MARK: - append / samples (no wrap)

    func test_emptyAtStart() {
        let r = PCMRingBuffer(capacity: 100)
        XCTAssertEqual(r.head, 0)
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.tail, 0)
        XCTAssertEqual(r.totalSamples, 0)
        XCTAssertEqual(r.samples(from: 0, to: 0), [])
    }

    func test_appendBelowCapacity_readsBack() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 50))
        XCTAssertEqual(r.head, 0)
        XCTAssertEqual(r.count, 50)
        XCTAssertEqual(r.tail, 50)
        XCTAssertEqual(r.samples(from: 0, to: 50), seq(0, 50))
        XCTAssertEqual(r.samples(from: 10, to: 20), seq(10, 10))
    }

    func test_appendMultipleBatches_preservesOrder() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 30))
        r.append(seq(30, 20))
        XCTAssertEqual(r.totalSamples, 50)
        XCTAssertEqual(r.samples(from: 0, to: 50), seq(0, 50))
    }

    // MARK: - samples() clamping

    func test_samples_clampsLow() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 10))
        // Asking from `-5` should clamp to 0 — never crash, never return
        // garbage.
        XCTAssertEqual(r.samples(from: -5, to: 5), seq(0, 5))
    }

    func test_samples_clampsHigh() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 10))
        XCTAssertEqual(r.samples(from: 5, to: 50), seq(5, 5))
    }

    func test_samples_invertedRangeReturnsEmpty() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 10))
        XCTAssertEqual(r.samples(from: 7, to: 3), [])
    }

    // MARK: - discard

    func test_discardAdvancesHead_absoluteIndicesStable() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 50))
        r.discard(beforeAbsolute: 30)

        XCTAssertEqual(r.head, 30)
        XCTAssertEqual(r.count, 20)
        XCTAssertEqual(r.tail, 50)
        // The absolute indices 30..<50 still address the same samples.
        XCTAssertEqual(r.samples(from: 30, to: 50), seq(30, 20))
        // Indices below `head` resolve to whatever still overlaps the
        // retained window — for [0..30) that's `[]`.
        XCTAssertEqual(r.samples(from: 0, to: 30), [])
    }

    func test_discardWontGoBackwards() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 50))
        r.discard(beforeAbsolute: 30)
        r.discard(beforeAbsolute: 10)  // older than head — should be a no-op
        XCTAssertEqual(r.head, 30)
        XCTAssertEqual(r.count, 20)
    }

    func test_discardClampsAtTail() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 50))
        r.discard(beforeAbsolute: 9_999)
        XCTAssertEqual(r.head, 50)
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Wrap-around correctness

    func test_appendBeyondCapacity_silentlyDropsOldest() {
        let r = PCMRingBuffer(capacity: 10)
        r.append(seq(0, 8))
        r.append(seq(8, 6))  // 8+6 = 14 > 10 → drop oldest 4
        XCTAssertEqual(r.head, 4, "head should advance past dropped samples")
        XCTAssertEqual(r.count, 10)
        XCTAssertEqual(r.tail, 14)
        XCTAssertEqual(r.samples(from: 4, to: 14), seq(4, 10))
    }

    func test_singleAppendLargerThanCapacity_keepsTail() {
        let r = PCMRingBuffer(capacity: 5)
        r.append(seq(0, 17))
        // We expect the trailing 5 samples (indices 12..<17 absolute).
        XCTAssertEqual(r.head, 12)
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r.tail, 17)
        XCTAssertEqual(r.samples(from: 12, to: 17), seq(12, 5))
    }

    func test_samples_acrossWrap() {
        let r = PCMRingBuffer(capacity: 10)
        r.append(seq(0, 7))
        r.discard(beforeAbsolute: 3)
        r.append(seq(7, 6))  // tail becomes 13. Storage wraps: slots 3..<10 hold 3..<10, slots 0..<3 hold 10..<13.
        XCTAssertEqual(r.head, 3)
        XCTAssertEqual(r.count, 10)
        XCTAssertEqual(r.tail, 13)
        // Range that straddles the wrap.
        XCTAssertEqual(r.samples(from: 8, to: 13), seq(8, 5))
        // Full retained window.
        XCTAssertEqual(r.samples(from: 3, to: 13), seq(3, 10))
    }

    // MARK: - recentSamples

    func test_recentSamples_returnsTrailing() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 50))
        XCTAssertEqual(r.recentSamples(count: 10), seq(40, 10))
    }

    func test_recentSamples_returnsEmptyWhenInsufficient() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 5))
        XCTAssertEqual(r.recentSamples(count: 10), [])
    }

    func test_recentSamples_acrossWrap() {
        let r = PCMRingBuffer(capacity: 10)
        r.append(seq(0, 8))
        r.append(seq(8, 6))  // tail 14, head 4
        XCTAssertEqual(r.recentSamples(count: 6), seq(8, 6))
    }

    // MARK: - reset

    func test_reset_clearsButKeepsAllocation() {
        let r = PCMRingBuffer(capacity: 100)
        r.append(seq(0, 50))
        r.discard(beforeAbsolute: 20)
        r.reset()
        XCTAssertEqual(r.head, 0)
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.tail, 0)
        // Round-trip: new session starts fresh from absolute 0.
        r.append(seq(0, 5))
        XCTAssertEqual(r.samples(from: 0, to: 5), seq(0, 5))
    }
}
