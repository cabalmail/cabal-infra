import XCTest

// Regression coverage for #1587.
//
// `AddressListView`'s row drew `Text(address.address)` raw with no line
// limit, so a row narrow enough to wrap an address hyphenated the unbreakable
// token and drew a character the address does not contain: measured as
// `…@longsubdomain-` / `probe0915.cabal-mail.com` on iPhone 17 and
// `b2f6s4mx@r8g3h5ne.ca-` / `bal-mail.net` in the 236pt iPad inspector, where
// 2 of 5 rows of a plausible account were wrong. `AddressDisplay.wrappable`
// is the fix #1547 established for the confirmations and #1578/#1589 carried
// to the watch rows and the New Address preview.
//
// The two things this scan pins, because neither has a unit-test seam:
//
// 1. The row goes through `wrappable`. A raw `Text(address.address)` coming
//    back is the reported defect.
// 2. What the row hands on stays raw. The zero-width spaces are real
//    characters, so a Copy that took the drawn string would paste an address
//    nobody can use (measured on the New Address preview, #1589: 60 of them
//    on the pasteboard). Both Copy paths and the row's accessibility label
//    read `address.address`, and nothing here is `.textSelection`-enabled.
//
// The view is a `View` with no seam for either rule — the layout engine
// decides where the hyphen lands — so this reads the source, in the shape
// `WatchAddressWrapSourceScanTests` set for the watch's copies of this
// defect. `AddressListView.swift` compiles into the iOS and macOS targets
// both, so one read covers every platform that draws the row.
//
// Deliberately out of scope, and left raw: `FromPicker`'s menu rows,
// `RuleEditorExtras`' forward-address list and the Settings From-address
// picker. Each draws an address in a `Text` and none has been measured to
// wrap — a scan asserting a rule nobody has shown applies there would be a
// claim, not a test.
final class AddressListRowWrapSourceScanTests: XCTestCase {

    private static let path = "Cabalmail/Views/AddressListView.swift"

    /// Rule 1: the row draws the wrappable address.
    func testTheRowDrawsTheWrappableAddress() throws {
        let code = Self.code(in: try Self.viewSource())
        XCTAssertTrue(
            code.contains("Text(AddressDisplay.wrappable(address.address))"),
            "draw the row's address through AddressDisplay.wrappable (#1587)"
        )
        XCTAssertEqual(
            try Self.rawAddressHits(in: code), 0,
            "a raw address Text hyphenates when the row wraps (#1587)"
        )
    }

    /// Rule 2: the zero-width spaces stay off the pasteboard and out of
    /// VoiceOver.
    func testTheRowHandsOnTheRawAddress() throws {
        let code = Self.code(in: try Self.viewSource())
        XCTAssertFalse(
            code.contains(".textSelection"),
            "selecting wrappable text copies its zero-width spaces (#1589)"
        )
        XCTAssertTrue(
            code.contains("copyToPasteboard(address.address)"),
            "the copy action must hand over the raw address, not the wrappable one (#1587)"
        )
        XCTAssertTrue(
            code.contains(#"accessibilityLabel("Copy \(address.address)")"#),
            "the row button's accessibility label must read the raw address (#1587)"
        )
        XCTAssertTrue(
            code.contains(".accessibilityLabel(address.address)"),
            "the drawn Text must pin the raw address for the contained subtree (#1587)"
        )
    }

    /// The detector on synthetic snippets, so a rewrite of the view can't
    /// make the scan above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address.address)"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text( address )\n    .font(.caption2)"), 1)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(AddressDisplay.wrappable(address.address))"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(AddressDisplay.revokeMessage(address.address))"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(address.comment ?? \"\")"), 0)
        XCTAssertEqual(try Self.rawAddressHits(in: "Text(\"Suspended\")"), 0)
    }

    /// A comment explaining the rule names the raw call, and is not one.
    func testTheScanReadsCodeNotProse() throws {
        XCTAssertEqual(try Self.rawAddressHits(in: Self.code(in: "/// was Text(address.address)")), 0)
        XCTAssertEqual(
            try Self.rawAddressHits(in: Self.code(in: "Text(address.address) // the old row")),
            1
        )
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheSourceIsReadable() throws {
        let source = try Self.viewSource()
        XCTAssertTrue(
            source.contains("struct AddressListView: View"),
            "\(Self.path) did not load"
        )
        XCTAssertTrue(
            source.contains("private func row(for address: Address)"),
            "the row builder — what this scan is about — is missing from the source"
        )
    }

    // MARK: - Corpus

    /// `Text(address)` or `Text(<anything>.address)`: the expressions this
    /// view holds a whole address in.
    private static func rawAddressHits(in body: String) throws -> Int {
        try body.ranges(of: Regex(#"\bText\(\s*(?:\w+\.)*address\s*\)"#)).count
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func viewSource() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
