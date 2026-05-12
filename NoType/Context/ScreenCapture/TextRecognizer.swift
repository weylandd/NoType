import CoreGraphics
import Foundation
import OSLog
import Vision

/// Vision wrapper that recognises text in a `CGImage` and returns lines
/// in reading order. Used by `ScreenCaptureContext`.
///
/// Uses the `.accurate` recognition level with language correction and
/// automatic language detection — Vision picks the best language model
/// for the visible glyphs without us having to declare a locale. Typical
/// cost on M-series for an active-window screenshot: 100–300 ms.
enum TextRecognizer {
    private static let log = Logger(subsystem: "app.notype", category: "ocr")

    enum RecognizerError: Error, LocalizedError {
        case requestFailed(Error)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let e): "Text recognition failed: \(e.localizedDescription)"
            }
        }
    }

    /// Recognise text in `image`. Returns one string per observation in
    /// reading order. Empty strings are filtered out. Never throws on
    /// "no text found" — returns an empty array instead.
    static func recognize(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: RecognizerError.requestFailed(error))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [String] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    let s = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return s.isEmpty ? nil : s
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let t0 = Date()
            do {
                try handler.perform([request])
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                Self.log.debug("recognize took \(ms)ms")
            } catch {
                continuation.resume(throwing: RecognizerError.requestFailed(error))
            }
        }
    }
}
