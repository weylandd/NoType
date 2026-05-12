import AVFoundation
import XCTest
@testable import NoType

/// Sanity-checks for the PCM → AAC-in-M4A encoder used to ship audio
/// chunks to Gemini. We don't (and can't) test transcoding fidelity in
/// unit tests — the system AAC encoder is a black box. Instead we
/// verify the produced container is well-formed and large enough to
/// account for the input PCM duration.
final class ChunkBuilderTests: XCTestCase {

    /// Build a synthetic mono 16 kHz float32 buffer holding a 440 Hz
    /// sine wave of the requested duration.
    private func sineWave(durationSec: Double, sampleRate: Double = 16_000) -> [Float] {
        let count = Int(durationSec * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let twoPiF = 2.0 * .pi * 440.0
        for i in 0..<count {
            out[i] = Float(sin(twoPiF * Double(i) / sampleRate)) * 0.5
        }
        return out
    }

    // MARK: - Happy path

    func test_encodeAAC_producesNonEmptyData() throws {
        let pcm = sineWave(durationSec: 0.5)  // 500 ms
        let data = try ChunkBuilder.encodeAAC(pcm)
        XCTAssertGreaterThan(data.count, 0, "encoder produced empty Data")
        // 500 ms @ 32 kbps ≈ 2000 bytes of payload. M4A container adds
        // ~600–1200 bytes of moov/mdat/ftyp atoms. Assert a generous
        // lower bound so we catch "the encoder wrote a header but no
        // audio frames" regressions.
        XCTAssertGreaterThan(data.count, 800, "suspiciously small AAC blob: \(data.count) bytes")
    }

    func test_encodeAAC_outputIsValidMP4Container() throws {
        let pcm = sineWave(durationSec: 1.0)
        let data = try ChunkBuilder.encodeAAC(pcm)

        // ISO BMFF / m4a containers always start with an `ftyp` box.
        // First 4 bytes are big-endian size; bytes 4..8 spell "ftyp".
        XCTAssertGreaterThan(data.count, 8)
        let typeBytes = data.subdata(in: 4..<8)
        let typeString = String(data: typeBytes, encoding: .ascii) ?? ""
        XCTAssertEqual(typeString, "ftyp", "first box must be ftyp, got \(typeString)")
    }

    func test_encodeAAC_isReadableByAVAudioFile() throws {
        // Round-trip: encode a known sine, write the resulting blob to
        // disk, open it as AVAudioFile, decode back to PCM, and verify
        // we got roughly the right number of frames at the right sample
        // rate. We do NOT compare audio data — AAC is lossy and the
        // encoder pre/post-rolls a few hundred ms.
        let inputDurationSec = 1.0
        let pcm = sineWave(durationSec: inputDurationSec)
        let blob = try ChunkBuilder.encodeAAC(pcm)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notype-chunkbuilder-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try blob.write(to: url)

        let file = try AVAudioFile(forReading: url)
        let outRate = file.fileFormat.sampleRate
        XCTAssertEqual(outRate, 16_000, "expected 16 kHz, got \(outRate)")
        XCTAssertEqual(file.fileFormat.channelCount, 1)

        let frames = file.length
        let outDurationSec = Double(frames) / outRate
        // AAC encoders emit priming + remainder padding (~2048 samples =
        // ~128 ms total at 16 kHz). Tolerate up to ±0.3 s.
        XCTAssertEqual(outDurationSec, inputDurationSec, accuracy: 0.3,
                       "round-tripped duration drifted too much: \(outDurationSec)s vs \(inputDurationSec)s")
    }

    // MARK: - Edge cases

    func test_encodeAAC_acceptsShortPCM() throws {
        // 150 ms — at the lower bound of what `RecordingSession.processBatch`
        // would ever ship (below this the chunk is skipped before we get here).
        // The encoder must still produce a valid container; the prior bug class
        // was "AVAudioFile encoder writes only ftyp+free atoms for very short
        // inputs because deinit hasn't flushed".
        let pcm = sineWave(durationSec: 0.15)
        let data = try ChunkBuilder.encodeAAC(pcm)

        XCTAssertGreaterThan(data.count, 200)
        let typeBytes = data.subdata(in: 4..<8)
        XCTAssertEqual(String(data: typeBytes, encoding: .ascii), "ftyp")
    }

    func test_encodeAAC_doesNotLeaveTempFiles() throws {
        // ChunkBuilder creates `aura-chunk-{UUID}.m4a` in /tmp during
        // encoding and is contractually obliged to remove it before
        // returning (defer try? FileManager.removeItem). Spot-check that
        // no orphans linger after a normal call. We can't pin the exact
        // filename (UUID), so we count matching entries before and after.
        let tmp = FileManager.default.temporaryDirectory
        let before = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
            .filter { $0.hasPrefix("aura-chunk-") }
            .count ?? 0

        _ = try ChunkBuilder.encodeAAC(sineWave(durationSec: 0.3))

        let after = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?
            .filter { $0.hasPrefix("aura-chunk-") }
            .count ?? 0

        XCTAssertEqual(after, before, "ChunkBuilder leaked a temp file")
    }
}
