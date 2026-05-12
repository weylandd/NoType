import Accelerate

/// Tiny FFT-based spectrum analyzer for the recording HUD.
///
/// Takes a window of 16 kHz mono float32 PCM and returns N normalized
/// magnitudes (one per visualized bar) covering the speech-relevant
/// 100 Hz – 6.4 kHz range with logarithmic spacing. Intended to be called
/// at ~30 fps from a `TimelineView`; per-call cost on Apple Silicon is
/// well under a millisecond.
///
/// `@MainActor` only because the HUD calls it on the main actor — the
/// underlying `vDSP.DFT` setup itself is allocated lazily and reused
/// across calls, so we don't want it to be reachable from concurrent
/// contexts.
@MainActor
enum AudioSpectrum {
    /// FFT window size. 1024 samples = 64 ms at 16 kHz, a comfortable
    /// trade between time and frequency resolution. Must be a power of 2
    /// (vDSP requirement).
    static let fftLength = 1024

    private static let dft: vDSP.DFT<Float>? = vDSP.DFT(
        count: fftLength,
        direction: .forward,
        transformType: .complexComplex,
        ofType: Float.self
    )

    /// Pre-computed Hann window. Reduces spectral leakage from
    /// non-periodic sample windows.
    private static let window: [Float] = vDSP.window(
        ofType: Float.self,
        usingSequence: .hanningDenormalized,
        count: fftLength,
        isHalfWindow: false
    )

    /// Returns `bandCount` normalized magnitudes in `[0, 1]`, indexed
    /// from low to high frequency. If `samples` is shorter than
    /// `fftLength` (e.g. very start of a session), returns all zeros.
    ///
    /// Two corrections shape the response for speech:
    ///
    /// 1. **Pink-noise compensation.** Speech energy falls roughly
    ///    6 dB/octave above ~500 Hz. Without compensation the low bars
    ///    swing wildly while the high bars barely move. We boost each
    ///    band's magnitude by `(centerFreq / 200)^0.6` (clamped ≥ 1)
    ///    before dB — about +19 dB at the top end, which restores a
    ///    visually balanced response.
    /// 2. **dB headroom.** Each band's mean magnitude (post-boost) is
    ///    mapped from `[-55 dB, +10 dB]` to `[0, 1]`. Wide range so
    ///    typical conversational speech sits around 60–70 % rather than
    ///    pinning the top.
    static func bands(from samples: [Float], bandCount: Int) -> [Float] {
        guard samples.count >= fftLength, let dft else {
            return Array(repeating: 0, count: bandCount)
        }

        // Window the trailing fftLength samples.
        var windowed = [Float](repeating: 0, count: fftLength)
        let tail = Array(samples.suffix(fftLength))
        vDSP.multiply(tail, window, result: &windowed)

        // Forward DFT (complex-complex with imaginary input zeroed).
        let imagIn = [Float](repeating: 0, count: fftLength)
        var realOut = [Float](repeating: 0, count: fftLength)
        var imagOut = [Float](repeating: 0, count: fftLength)
        dft.transform(
            inputReal:      windowed,
            inputImaginary: imagIn,
            outputReal:     &realOut,
            outputImaginary: &imagOut
        )

        // Magnitudes for the lower half (Nyquist = sampleRate / 2).
        let halfN = fftLength / 2
        var mags = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            let r = realOut[i]
            let im = imagOut[i]
            mags[i] = sqrtf(r * r + im * im)
        }

        // Log-spaced bins from 100 Hz to 6.4 kHz (covers speech formants
        // without wasting bars on the >7 kHz region that's mostly hiss
        // for our 16 kHz capture rate).
        let sampleRate: Float = 16_000
        let lowHz:  Float = 100
        let highHz: Float = 6_400
        let nyquistRatio = Float(fftLength) / sampleRate

        var result = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let t0 = Float(b)     / Float(bandCount)
            let t1 = Float(b + 1) / Float(bandCount)
            let f0 = lowHz * powf(highHz / lowHz, t0)
            let f1 = lowHz * powf(highHz / lowHz, t1)

            let i0 = max(1,         Int(f0 * nyquistRatio))
            let i1 = min(halfN - 1, max(i0 + 1, Int(f1 * nyquistRatio)))

            var sum: Float = 0
            for i in i0..<i1 { sum += mags[i] }
            let avg = sum / Float(max(1, i1 - i0))

            // Pink-noise compensation: boost higher bands to offset the
            // ~6 dB/octave roll-off of speech.
            let centerFreq = sqrtf(f0 * f1)
            let pinkGain = max(1, powf(centerFreq / 200, 0.6))
            let boosted = avg * pinkGain

            // Convert magnitude to dB and clip to a sensible window.
            let db = 20 * log10f(max(1e-6, boosted))
            let normalized = max(0, min(1, (db + 55) / 65))
            result[b] = normalized
        }
        return result
    }
}
