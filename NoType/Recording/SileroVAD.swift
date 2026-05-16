import CoreML
import Foundation
import OSLog

/// CoreML wrapper around `SileroVAD.mlmodelc` (the unified-256 ms variant of
/// Silero v6, repackaged from FluidInference/silero-vad-coreml on Hugging
/// Face — see ADR-002 in `docs/decisions.md`).
///
/// The model is **stateful**: each call consumes 4096 audio samples plus a
/// 64-sample look-back from the previous call, returns a probability and the
/// LSTM state to feed back next time. Wrapping that lifecycle is the whole
/// reason this class exists.
///
/// Tensor contract (from the bundled `metadata.json`):
///
/// | Direction | Name              | Shape    | Notes                          |
/// |-----------|-------------------|----------|--------------------------------|
/// | input     | `audio_input`     | [1,4160] | 64 ctx + 4096 new samples      |
/// | input     | `hidden_state`    | [1,128]  | LSTM hidden, zeros on first call|
/// | input     | `cell_state`      | [1,128]  | LSTM cell, zeros on first call |
/// | output    | `vad_output`      | [1,1,1]  | Speech probability ∈ [0,1]     |
/// | output    | `new_hidden_state`| [1,128]  | Feed back next call            |
/// | output    | `new_cell_state`  | [1,128]  | Feed back next call            |
///
/// Sample rate is fixed at 16 kHz; the recorder must resample before feeding
/// frames here.
actor SileroVAD {
    private static let log = Logger(subsystem: "app.notype", category: "vad")

    /// Number of new samples consumed per inference (256 ms at 16 kHz).
    static let chunkSize = 4_096
    /// Look-back samples prepended to each call's audio input. Carried over
    /// from the previous call's tail.
    static let contextSize = 64
    /// Total length of the `audio_input` tensor.
    static let inputLength = chunkSize + contextSize  // 4160
    /// Sample rate the model was trained at; non-negotiable.
    static let sampleRate: Double = 16_000
    /// LSTM hidden/cell state dimensionality.
    private static let stateSize = 128

    enum VADError: Error, LocalizedError {
        case modelNotFound
        case modelLoadFailed(Error)
        case inputShapeMismatch(expected: Int, got: Int)
        case predictionFailed(Error)
        case missingOutput(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                "SileroVAD.mlmodelc is missing from the app bundle."
            case .modelLoadFailed(let e):
                "Couldn't load SileroVAD: \(e.localizedDescription)"
            case .inputShapeMismatch(let expected, let got):
                "VAD frame size mismatch: expected \(expected) samples, got \(got)."
            case .predictionFailed(let e):
                "VAD prediction failed: \(e.localizedDescription)"
            case .missingOutput(let name):
                "VAD output is missing the '\(name)' tensor."
            }
        }
    }

    private let model: MLModel
    /// Carried-over LSTM state. Reset to zeros at session start.
    private var hiddenState: MLMultiArray
    private var cellState: MLMultiArray
    /// Last 64 samples of the most recent `audio_input` payload — prepended
    /// to the next call so the convolutional encoder sees continuous audio
    /// across call boundaries.
    private var carriedContext: [Float]

    init() throws {
        guard let url = Bundle.main.url(
            forResource: "SileroVAD",
            withExtension: "mlmodelc"
        ) else {
            throw VADError.modelNotFound
        }

        let config = MLModelConfiguration()
        // .all picks the best available unit (ANE → GPU → CPU). The 256 ms
        // unified model lands on ANE on Apple Silicon.
        config.computeUnits = .all

        do {
            self.model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            throw VADError.modelLoadFailed(error)
        }

        self.hiddenState = try Self.zeroStateArray()
        self.cellState = try Self.zeroStateArray()
        self.carriedContext = Array(repeating: 0, count: Self.contextSize)

        Self.log.info("SileroVAD loaded (256ms, ANE-eligible)")
    }

    /// Drop accumulated state so the next session starts fresh. Call before
    /// `RecordingSession.start()`.
    func reset() throws {
        self.hiddenState = try Self.zeroStateArray()
        self.cellState = try Self.zeroStateArray()
        self.carriedContext = Array(repeating: 0, count: Self.contextSize)
    }

    /// Run one inference pass. `samples` must be exactly `chunkSize` Float32
    /// PCM samples at 16 kHz. Returns the speech probability ∈ [0, 1].
    func probability(for samples: [Float]) throws -> Float {
        guard samples.count == Self.chunkSize else {
            throw VADError.inputShapeMismatch(expected: Self.chunkSize, got: samples.count)
        }

        // audio_input = [carriedContext (64)] ++ [samples (4096)]
        let audioInput = try MLMultiArray(shape: [1, NSNumber(value: Self.inputLength)], dataType: .float32)
        // .dataPointer is a raw Float pointer for .float32 arrays.
        let audioPtr = audioInput.dataPointer.bindMemory(to: Float.self, capacity: Self.inputLength)
        for i in 0..<Self.contextSize {
            audioPtr[i] = carriedContext[i]
        }
        // Throws from inside the closure if `baseAddress` is ever nil
        // (only reachable if a future refactor loosens the count guard
        // above). A bare `return` would only escape the closure and
        // leave the trailing 4096 floats of `audio_input` uninitialised
        // — CoreML would happily classify garbage as speech.
        try samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else {
                throw VADError.inputShapeMismatch(expected: Self.chunkSize, got: 0)
            }
            audioPtr.advanced(by: Self.contextSize)
                .update(from: base, count: Self.chunkSize)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input":  audioInput,
            "hidden_state": hiddenState,
            "cell_state":   cellState,
        ])

        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: input)
        } catch {
            throw VADError.predictionFailed(error)
        }

        guard let prob = output.featureValue(for: "vad_output")?.multiArrayValue else {
            throw VADError.missingOutput("vad_output")
        }
        guard let nextHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue else {
            throw VADError.missingOutput("new_hidden_state")
        }
        guard let nextCell = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
            throw VADError.missingOutput("new_cell_state")
        }

        self.hiddenState = nextHidden
        self.cellState = nextCell

        // Update carried context: last 64 samples of the *new* audio payload.
        // (Not of audio_input — we only carry forward genuine audio, not
        // previous context.)
        let tailStart = Self.chunkSize - Self.contextSize
        for i in 0..<Self.contextSize {
            carriedContext[i] = samples[tailStart + i]
        }

        // vad_output is shape [1, 1, 1]; first element is the probability.
        let scalar = prob[0].floatValue
        return scalar
    }

    /// Convenience: zero-filled [1, 128] Float32 array.
    private static func zeroStateArray() throws -> MLMultiArray {
        let arr = try MLMultiArray(
            shape: [1, NSNumber(value: stateSize)],
            dataType: .float32
        )
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: stateSize)
        for i in 0..<stateSize { ptr[i] = 0 }
        return arr
    }
}
