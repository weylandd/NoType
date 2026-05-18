import XCTest
@testable import NoType

/// Pins the bundled `SupportedLanguages.json` resource — the picker
/// and the `User languages:` cache-prefix section both depend on this
/// list. A decoding regression would silently empty the picker, so we
/// keep the contract explicit here.
final class SupportedLanguagesTests: XCTestCase {

    func test_bundle_loadsAtLeastEightyEntries() {
        // The curated list ships ~100 entries (plan §584-646). Floor
        // at 80 leaves headroom for future trims without churning
        // this test.
        XCTAssertGreaterThanOrEqual(SupportedLanguages.all.count, 80,
            "SupportedLanguages.json should ship at least 80 curated entries")
    }

    func test_bundle_containsCommonLookups() {
        // English / Russian / Chinese / Japanese — sanity-check that
        // the major language codes are present and decoded into the
        // expected native + english names.
        let en = SupportedLanguages.lookup("en")
        XCTAssertNotNil(en, "en (English) must be present")
        XCTAssertEqual(en?.englishName, "English")

        let ru = SupportedLanguages.lookup("ru")
        XCTAssertNotNil(ru, "ru (Russian) must be present")
        XCTAssertEqual(ru?.englishName, "Russian")

        let zh = SupportedLanguages.lookup("zh")
        XCTAssertNotNil(zh, "zh (Chinese) must be present")
        XCTAssertEqual(zh?.englishName, "Chinese")

        let ja = SupportedLanguages.lookup("ja")
        XCTAssertNotNil(ja, "ja (Japanese) must be present")
        XCTAssertEqual(ja?.englishName, "Japanese")
    }

    func test_bundle_codesAreUnique() {
        let codes = SupportedLanguages.all.map { $0.code }
        XCTAssertEqual(Set(codes).count, codes.count,
            "Each BCP-47 code must appear at most once in the bundled list")
    }

    func test_byCode_indexCoversWholeList() {
        XCTAssertEqual(SupportedLanguages.byCode.count, SupportedLanguages.all.count,
            "byCode index must cover every entry in `all`")
    }

    // MARK: - filter

    func test_filter_emptyQueryReturnsAll() {
        let result = SupportedLanguages.filter(SupportedLanguages.all, query: "")
        XCTAssertEqual(result.count, SupportedLanguages.all.count)
    }

    func test_filter_whitespaceQueryReturnsAll() {
        let result = SupportedLanguages.filter(SupportedLanguages.all, query: "   ")
        XCTAssertEqual(result.count, SupportedLanguages.all.count)
    }

    func test_filter_caseInsensitiveEnglishNameMatch() {
        let result = SupportedLanguages.filter(SupportedLanguages.all, query: "RUSSIAN")
        XCTAssertTrue(result.contains { $0.code == "ru" })
    }

    func test_filter_caseInsensitiveCodeMatch() {
        let result = SupportedLanguages.filter(SupportedLanguages.all, query: "JA")
        XCTAssertTrue(result.contains { $0.code == "ja" })
    }

    func test_filter_nativeNameMatch() {
        // "Русский" — typing in native script must find the entry.
        let result = SupportedLanguages.filter(SupportedLanguages.all, query: "Русский")
        XCTAssertTrue(result.contains { $0.code == "ru" })
    }

    func test_filter_noMatchReturnsEmpty() {
        let result = SupportedLanguages.filter(
            SupportedLanguages.all,
            query: "definitely-no-such-language-anywhere"
        )
        XCTAssertTrue(result.isEmpty)
    }
}
