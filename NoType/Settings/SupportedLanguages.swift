import Foundation
import OSLog

/// One BCP-47 language entry shipped in the bundled
/// `SupportedLanguages.json` resource. `code` is the BCP-47 tag that
/// flows into `ContextSnapshot.userLanguages` (and the
/// `User languages:` Gemini cache-prefix section); `name` is the
/// native-script display label for the picker; `englishName` is the
/// search-friendly fallback used by the picker's filter so a user
/// typing "russian" still matches "Русский".
struct SupportedLanguage: Codable, Hashable, Sendable {
    let code: String
    let name: String
    let englishName: String
}

/// Loader for the bundled `SupportedLanguages.json` resource.
///
/// The list is a curated Gemini-supported subset (~100 entries) — see
/// plan `2026-05-18-001-feat-settings-screen-plan.md` §584-646. The
/// list is loaded once at first access and cached for the lifetime of
/// the process. Decoding failures collapse to an empty list and log
/// at `error` level; the Settings → System picker degrades to "no
/// languages available" rather than crashing.
enum SupportedLanguages {
    private static let log = Logger(subsystem: "app.notype", category: "languages")
    private static let resourceName = "SupportedLanguages"
    private static let resourceExt = "json"

    /// Filter helper used by the picker — case-insensitive substring
    /// match against `code`, `name` (native), or `englishName`. Pure
    /// function so `OutputLanguagePickerTests` can pin behaviour
    /// without standing up a SwiftUI render harness.
    static func filter(_ entries: [SupportedLanguage], query: String) -> [SupportedLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let needle = trimmed.lowercased()
        return entries.filter { entry in
            entry.code.lowercased().contains(needle)
                || entry.name.lowercased().contains(needle)
                || entry.englishName.lowercased().contains(needle)
        }
    }

    /// Cached list of all bundled supported languages. Returns an
    /// empty array when the resource is missing or malformed (rare —
    /// the JSON ships with the app).
    static let all: [SupportedLanguage] = loadFromBundle()

    /// O(1) lookup `code → SupportedLanguage`. Populated alongside
    /// `all`. Useful for the picker's "selected chip" strip which
    /// needs to render the native name for codes the user has saved.
    static let byCode: [String: SupportedLanguage] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
    }()

    /// Resolve a saved BCP-47 code to its `SupportedLanguage` (when
    /// the code is in the bundled list) or `nil` (when the user
    /// previously selected a code that we later dropped from the
    /// list — the chip falls back to rendering the bare code).
    static func lookup(_ code: String) -> SupportedLanguage? {
        byCode[code]
    }

    private static func loadFromBundle() -> [SupportedLanguage] {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExt) else {
            log.error("SupportedLanguages.json missing from bundle")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([SupportedLanguage].self, from: data)
        } catch {
            log.error("SupportedLanguages.json decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
