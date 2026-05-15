import Foundation

/// Fixed-capacity ring buffer for 16 kHz mono float32 PCM with absolute
/// sample indexing. Used by `AudioRecorder` as the session-scoped storage
/// the VAD consumer and `ChunkBuilder` slice from.
///
/// **Why not a plain `[Float]` + `removeFirst`.** That was the previous
/// implementation; `removeFirst` is O(N) (memmove of every retained
/// sample). For a session that talks continuously through several
/// 30-second force-cuts that adds up. A ring with wrap-around writes is
/// O(1) per chunk dispatched, regardless of session length.
///
/// **Absolute indices.** Callers (`PauseDetector`, `RecordingSession`)
/// hold sample positions across chunk boundaries and want them stable
/// even after we discard older data. Internally we store the ring's
/// `head` (absolute index of the oldest valid sample) and a `count`
/// (number of valid samples currently in storage). The relative storage
/// slot of an absolute index `abs` is `Int(abs % capacity)`.
///
/// **Overflow policy.** If the producer outpaces the consumer (very
/// long monologue with no force-cuts ever firing — shouldn't happen
/// today since `PauseDetector.maxChunkSamples = 30 s`, but defensive),
/// the oldest samples are dropped silently. `head` advances; absolute
/// indices the caller still holds for the dropped range will silently
/// return empty slices.
///
/// **Concurrency.** No internal lock — the type is `@unchecked Sendable`
/// because the only mutating point in production is `AudioRecorder`'s
/// `lock`-guarded tap path. Tests drive it single-threaded. If anyone
/// ever uses this from multiple actors directly, wrap it in a lock.
final class PCMRingBuffer: @unchecked Sendable {
    /// Fixed maximum samples retained at any moment. Sized at construction.
    let capacity: Int

    /// Absolute sample index of the oldest sample currently in storage.
    /// Monotonically non-decreasing. Bumped by `discard(beforeAbsolute:)`
    /// and (on overflow) by `append(_:)`.
    private(set) var head: Int = 0

    /// Number of valid samples currently held. Always in `0...capacity`.
    private(set) var count: Int = 0

    /// `[head + count)` — absolute index past the last valid sample.
    /// Private — call sites and tests use `totalSamples` (same value, more
    /// legible at the read site: "how many samples has this session
    /// captured so far"). Internal uses still read `tail` for brevity.
    private var tail: Int { head + count }

    /// Same as `tail` — the public accessor.
    var totalSamples: Int { tail }

    /// Underlying storage. We use `ContiguousArray` for predictable
    /// memory layout and `UnsafeMutableBufferPointer` access in hot
    /// paths.
    private var storage: ContiguousArray<Float>

    init(capacity: Int) {
        precondition(capacity > 0, "PCMRingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = ContiguousArray(repeating: 0, count: capacity)
    }

    /// Reset to an empty buffer, with `head` zeroed. Called at session
    /// start. Storage stays allocated.
    func reset() {
        head = 0
        count = 0
    }

    /// Append `samples` to the tail of the ring. If `count + samples.count`
    /// exceeds `capacity`, oldest samples are silently overwritten and
    /// `head` advances to compensate.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let n = samples.count
        if n >= capacity {
            // Pathological: a single tap larger than the whole buffer.
            // Keep only the trailing `capacity` samples; head jumps
            // forward to match. Slots are still indexed by absolute
            // position mod capacity so `samples(from:to:)` reads them
            // back in the right order.
            let droppedFromInput = n - capacity
            let newHead = tail + droppedFromInput
            samples.withUnsafeBufferPointer { src in
                storage.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<capacity {
                        let slot = (newHead + i) % capacity
                        dst[slot] = src[droppedFromInput + i]
                    }
                }
            }
            head = newHead
            count = capacity
            return
        }
        let overflow = (count + n) - capacity
        if overflow > 0 {
            head += overflow
            count -= overflow
        }
        let writeStartAbs = tail
        samples.withUnsafeBufferPointer { src in
            storage.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let slot = (writeStartAbs + i) % capacity
                    dst[slot] = src[i]
                }
            }
        }
        count += n
    }

    /// Drop samples whose absolute index is `< absoluteIndex`. Clamped at
    /// `head` (no going backwards) and at `tail` (no going past valid
    /// data). After the call, `head == max(head, min(absoluteIndex, tail))`.
    func discard(beforeAbsolute absoluteIndex: Int) {
        let target = min(max(head, absoluteIndex), tail)
        let drop = target - head
        guard drop > 0 else { return }
        head = target
        count -= drop
    }

    /// Return the half-open range `[from, to)` of samples. Out-of-range
    /// indices are clamped silently — this is a slicing helper, not a
    /// contract enforcer. Returns `[]` when the requested range no
    /// longer overlaps the retained window.
    func samples(from: Int, to: Int) -> [Float] {
        let absLo = max(head, from)
        let absHi = max(absLo, min(tail, to))
        let n = absHi - absLo
        guard n > 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(n)
        // Two possible layouts in `storage`:
        // 1. Contiguous (`absLo` and `absHi - 1` map to the same wrap).
        // 2. Wrapped — split into [absLo … capacity) + [0 … remainder).
        let startSlot = absLo % capacity
        if startSlot + n <= capacity {
            storage.withUnsafeBufferPointer { src in
                for i in 0..<n {
                    out.append(src[startSlot + i])
                }
            }
        } else {
            let firstChunk = capacity - startSlot
            let secondChunk = n - firstChunk
            storage.withUnsafeBufferPointer { src in
                for i in 0..<firstChunk {
                    out.append(src[startSlot + i])
                }
                for i in 0..<secondChunk {
                    out.append(src[i])
                }
            }
        }
        return out
    }

    /// Return the trailing `n` samples currently held, or `[]` if fewer
    /// than `n` are available. Used by the recording HUD's live
    /// spectrum meter (~30 fps).
    func recentSamples(count n: Int) -> [Float] {
        guard n > 0, count >= n else { return [] }
        let from = tail - n
        return samples(from: from, to: tail)
    }
}
