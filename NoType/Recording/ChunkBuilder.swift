import AVFoundation
import Foundation
import OSLog

/// Encodes a slice of 16 kHz mono float32 PCM into an AAC-in-M4A blob ready
/// to ship to Gemini. We round-trip through a temp file because
/// `AVAudioFile`'s AAC encoder is the simplest path that uses Apple's
/// hardware encoder on Apple Silicon — about 4 KB per second of speech at
/// 32 kbps.
enum ChunkBuilder {
    private static let log = Logger(subsystem: "app.notype", category: "recording")

    enum ChunkError: Error, LocalizedError {
        case formatCreate
        case bufferAlloc
        case fileCreate(Error)
        case writeFailed(Error)
        case readFailed(Error)

        var errorDescription: String? {
            switch self {
            case .formatCreate:           "Couldn't create AAC encoder format."
            case .bufferAlloc:            "Couldn't allocate PCM buffer for chunk encoding."
            case .fileCreate(let e):      "Couldn't open chunk file: \(e.localizedDescription)"
            case .writeFailed(let e):     "Chunk write failed: \(e.localizedDescription)"
            case .readFailed(let e):      "Chunk read-back failed: \(e.localizedDescription)"
            }
        }
    }

    /// Encode `pcm` (16 kHz mono float32) to AAC m4a. Returns the encoded
    /// `Data`; the temp file is deleted before this function returns.
    static func encodeAAC(_ pcm: [Float], sampleRate: Double = 16_000) throws -> Data {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ChunkError.formatCreate
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-chunk-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey:   32_000,
        ]

        // Scope the `AVAudioFile` so its deinit runs before we read the
        // file back. The encoder flushes its internal queue + writes the
        // m4a `moov` atom on deinit; reading earlier yields a truncated
        // file.
        do {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw ChunkError.fileCreate(error)
            }

            let frames = AVAudioFrameCount(pcm.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw ChunkError.bufferAlloc
            }
            buffer.frameLength = frames
            guard let dst = buffer.floatChannelData?[0] else {
                throw ChunkError.bufferAlloc
            }
            pcm.withUnsafeBufferPointer { src in
                // `baseAddress` is non-nil for any non-empty buffer; `pcm`
                // is non-empty here (caller asserts ≥ 150 ms of samples).
                // The guard documents the invariant and makes the path
                // safe under a future refactor that loosens it.
                guard let base = src.baseAddress else { return }
                dst.update(from: base, count: pcm.count)
            }

            do {
                try file.write(from: buffer)
            } catch {
                throw ChunkError.writeFailed(error)
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ChunkError.readFailed(error)
        }

        let ms = Int(Double(pcm.count) / sampleRate * 1000)
        Self.log.debug("encoded \(ms)ms PCM → \(data.count) bytes AAC")
        return data
    }
}
