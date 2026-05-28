import XCTest
@testable import CabalmailKit

final class RecipientAutocompleteTests: XCTestCase {

    // MARK: - trailingToken

    func testTrailingTokenOnEmptyFieldIsEmpty() {
        XCTAssertEqual(RecipientAutocomplete.trailingToken(in: ""), "")
    }

    func testTrailingTokenIsWholeFieldWhenNoComma() {
        XCTAssertEqual(RecipientAutocomplete.trailingToken(in: "jane"), "jane")
        XCTAssertEqual(RecipientAutocomplete.trailingToken(in: "  jane  "), "jane")
    }

    func testTrailingTokenIsTextAfterLastComma() {
        XCTAssertEqual(
            RecipientAutocomplete.trailingToken(in: "alice@x, jane"),
            "jane"
        )
        XCTAssertEqual(
            RecipientAutocomplete.trailingToken(in: "alice@x, bob@y, ja"),
            "ja"
        )
    }

    func testTrailingTokenIsEmptyJustAfterCommaAndSpace() {
        XCTAssertEqual(RecipientAutocomplete.trailingToken(in: "alice@x, "), "")
        XCTAssertEqual(RecipientAutocomplete.trailingToken(in: "alice@x,"), "")
    }

    // MARK: - applying(suggestion:toFieldText:)

    func testApplyingSuggestionToEmptyField() {
        let suggestion = RecipientSuggestion(name: "Jane Doe", email: "jane@x.com")
        let result = RecipientAutocomplete.applying(suggestion: suggestion, toFieldText: "jan")
        XCTAssertEqual(result, "\"Jane Doe\" <jane@x.com>, ")
    }

    func testApplyingSuggestionReplacesOnlyTrailingToken() {
        let suggestion = RecipientSuggestion(name: "Jane Doe", email: "jane@x.com")
        let result = RecipientAutocomplete.applying(
            suggestion: suggestion,
            toFieldText: "alice@y, ja"
        )
        XCTAssertEqual(result, "alice@y, \"Jane Doe\" <jane@x.com>, ")
    }

    func testApplyingSuggestionWithNoName() {
        let suggestion = RecipientSuggestion(name: nil, email: "bob@x.com")
        let result = RecipientAutocomplete.applying(suggestion: suggestion, toFieldText: "bob")
        XCTAssertEqual(result, "bob@x.com, ")
    }

    func testApplyingSuggestionAfterTrailingComma() {
        let suggestion = RecipientSuggestion(name: "Jane Doe", email: "jane@x.com")
        let result = RecipientAutocomplete.applying(
            suggestion: suggestion,
            toFieldText: "alice@y, "
        )
        XCTAssertEqual(result, "alice@y, \"Jane Doe\" <jane@x.com>, ")
    }

    // MARK: - suggestions(for:from:limit:)

    private let janeDoe = RecipientSuggestion(name: "Jane Doe", email: "jane@x.com")
    private let janeAnnSmith = RecipientSuggestion(name: "Mary Ann Smith", email: "mary.ann@x.com")
    private let jeanLuc = RecipientSuggestion(name: "Jean-Luc Picard", email: "captain@enterprise.fed")
    private let bobNoName = RecipientSuggestion(name: nil, email: "bob@x.com")
    private let acmeCorp = RecipientSuggestion(name: "Acme Corp", email: "info@acme.com")

    private var fixtures: [RecipientSuggestion] {
        [janeDoe, janeAnnSmith, jeanLuc, bobNoName, acmeCorp]
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(RecipientAutocomplete.suggestions(for: "", from: fixtures).isEmpty)
        XCTAssertTrue(RecipientAutocomplete.suggestions(for: "   ", from: fixtures).isEmpty)
    }

    func testNamePrefixMatch() {
        let results = RecipientAutocomplete.suggestions(for: "jan", from: fixtures)
        XCTAssertEqual(results.first, janeDoe)
    }

    func testNameWordBoundaryMatch() {
        let results = RecipientAutocomplete.suggestions(for: "ann", from: fixtures)
        XCTAssertTrue(results.contains(janeAnnSmith), "Should match middle word 'Ann' in 'Mary Ann Smith'")
    }

    func testHyphenatedNameWordMatch() {
        let results = RecipientAutocomplete.suggestions(for: "luc", from: fixtures)
        XCTAssertTrue(results.contains(jeanLuc), "Should match 'Luc' in 'Jean-Luc Picard'")
    }

    func testEmailLocalPartPrefix() {
        let results = RecipientAutocomplete.suggestions(for: "bob", from: fixtures)
        XCTAssertEqual(results.first, bobNoName)
    }

    func testCaseInsensitive() {
        let results = RecipientAutocomplete.suggestions(for: "JANE", from: fixtures)
        XCTAssertEqual(results.first, janeDoe)
    }

    func testRankingPrefersNameWordOverEmailPrefix() {
        let nameMatch = RecipientSuggestion(name: "Janet Foo", email: "jfoo@x.com")
        let emailMatch = RecipientSuggestion(name: "Other", email: "janitor@x.com")
        let results = RecipientAutocomplete.suggestions(
            for: "jan",
            from: [emailMatch, nameMatch]
        )
        XCTAssertEqual(results.first, nameMatch, "name-word hit ranks above email-prefix hit")
    }

    func testSubstringMatchAsLastResort() {
        let suggestion = RecipientSuggestion(name: "Wendy", email: "support@example.com")
        let results = RecipientAutocomplete.suggestions(for: "port", from: [suggestion])
        XCTAssertEqual(results.first, suggestion)
    }

    func testLimitCapsResults() {
        let many = (0..<20).map {
            RecipientSuggestion(name: "Test \($0)", email: "test\($0)@x.com")
        }
        let results = RecipientAutocomplete.suggestions(for: "test", from: many, limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - RecipientSuggestion.formatted

    func testFormattedWithName() {
        let suggestion = RecipientSuggestion(name: "Jane Doe", email: "jane@x.com")
        XCTAssertEqual(suggestion.formatted, "\"Jane Doe\" <jane@x.com>")
    }

    func testFormattedWithoutName() {
        let suggestion = RecipientSuggestion(name: nil, email: "bob@x.com")
        XCTAssertEqual(suggestion.formatted, "bob@x.com")
    }

    func testFormattedWithEmptyName() {
        let suggestion = RecipientSuggestion(name: "", email: "bob@x.com")
        XCTAssertEqual(suggestion.formatted, "bob@x.com")
    }
}
