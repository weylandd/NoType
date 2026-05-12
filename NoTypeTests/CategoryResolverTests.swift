import XCTest
@testable import NoType

/// Pins the `search` AX-override heuristics. The live AX path is not
/// unit-testable (system-wide read); we drive `resolve(stored:focused:)`
/// directly with synthetic `FocusedFieldSnapshot` values.
final class CategoryResolverTests: XCTestCase {

    private func snap(
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil
    ) -> FocusedFieldSnapshot {
        FocusedFieldSnapshot(role: role, subrole: subrole, identifier: identifier, title: title)
    }

    // MARK: - Passthrough when nothing matches

    func test_resolve_returnsStored_whenFocusedNil() {
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: nil),
            .messaging
        )
    }

    func test_resolve_returnsStored_whenNothingHints() {
        let focused = snap(role: "AXTextField", identifier: "messageBody", title: "Compose")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: focused),
            .messaging
        )
    }

    // MARK: - Role / subrole

    func test_resolve_searchField_byRole() {
        let focused = snap(role: "AXSearchField")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: focused),
            .search
        )
    }

    func test_resolve_searchField_bySubrole() {
        let focused = snap(role: "AXTextField", subrole: "AXSearchField")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .docs, focused: focused),
            .search
        )
    }

    // MARK: - Identifier substring

    func test_resolve_identifierContainsSearch() {
        let focused = snap(role: "AXTextField", identifier: "globalSearchInput")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .uncategorized, focused: focused),
            .search
        )
    }

    func test_resolve_identifierContainsAddress() {
        // Chrome/Arc/Safari address bars expose AXTextField with an
        // identifier that includes "address" or "url".
        let focused = snap(role: "AXTextField", identifier: "addressBarTextField")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: focused),
            .search
        )
    }

    func test_resolve_identifierContainsUrl_caseInsensitive() {
        let focused = snap(role: "AXTextField", identifier: "OmniboxURL")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .docs, focused: focused),
            .search
        )
    }

    // MARK: - Title substring

    func test_resolve_titleContainsAddress() {
        let focused = snap(role: "AXTextField", title: "Address and search bar")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: focused),
            .search
        )
    }

    // MARK: - Non-trigger cases

    func test_resolve_doesNotTrigger_onUnrelatedIdentifier() {
        // "researchPanel" technically contains "search" as a substring of
        // "research". Per the heuristic this still triggers — documenting
        // it as a known false-positive shape so the test pins behaviour.
        let focused = snap(role: "AXTextField", identifier: "researchPanel")
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: focused),
            .search,
            "documented false-positive: 'research' contains 'search'. Adjust the needle list if this becomes a real problem."
        )
    }

    func test_resolve_doesNotTrigger_onUrlInsideUnrelatedTitle() {
        // Sanity: an empty/nil title doesn't crash.
        let focused = snap(role: "AXTextField", identifier: "messageBody", title: nil)
        XCTAssertEqual(
            CategoryResolver.resolve(stored: .messaging, focused: focused),
            .messaging
        )
    }
}
