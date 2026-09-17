import XCTest

// Regression coverage for #1589.
//
// The New Address sheet's preview line drew the composed address raw in both
// platform branches, so a long address wrapping on iPhone hyphenated the
// unbreakable token: `…probe0915xyza.ca-` / `bal-mail.com`, and one character
// later `….-` / `cabal-mail.com` — a hyphen straight after the dot. The tester
// reproduced the same sequence on iPad, about 88 characters in against the
// iPhone's 63. `AddressDisplay.wrappable` is the fix #1547 established.
//
// The two things this scan pins, because both were measured on the sheet and
// neither has a unit-test seam:
//
// 1. The preview goes through `wrappable`. A raw `Text(preview)` coming back
//    is the reported defect.
// 2. The wrappable string is never offered to `.textSelection`. Its
//    zero-width spaces are real characters: with selection enabled, Copy put
//    60 of them on the simulator pasteboard, which is a broken paste — a
//    worse bug than the drawn hyphen. The row carries a `Copy Address` action
//    over the raw string instead.
//
// `NewAddressSheet` is a `View` with no seam for either rule — the layout
// engine decides where the hyphen lands, and the pasteboard is UIKit's — so
// this reads the source, in the shape `WatchAddressWrapSourceScanTests` set
// for the watch's copies of this defect.
//
// The iOS/macOS address *rows* stay outside this scan, as they are outside
// the watch one: they are a different view, pinned by
// `AddressListRowWrapSourceScanTests` since #1587 measured them inserting a
// hyphen too (on iPhone and in the iPad inspector, though not on macOS 27).
final class NewAddressPreviewWrapSourceScanTests: XCTestCase {

    private static let path = "Cabalmail/Views/NewAddressSheet.swift"

    /// Rule 1: both branches draw the preview through `wrappable`.
    func testThePreviewDrawsTheWrappableAddress() throws {
        let code = Self.code(in: try Self.sheetSource())
        XCTAssertTrue(
            code.contains("Text(AddressDisplay.wrappable(preview))"),
            "draw the preview through AddressDisplay.wrappable (#1589)"
        )
        XCTAssertEqual(
            try Self.rawPreviewHits(in: code), 0,
            "a raw preview Text hyphenates when it wraps (#1589)"
        )
        // Both platform branches reach the same drawing, so a later edit to
        // one of them can't quietly reinstate the raw Text in the other.
        XCTAssertEqual(
            code.ranges(of: "addressPreview(preview)").count, 2,
            "macContent and formContent should share one preview row"
        )
    }

    /// Rule 2: the zero-width spaces stay off the pasteboard.
    func testThePreviewIsNotSelectableAndCopiesTheRawAddress() throws {
        let code = Self.code(in: try Self.sheetSource())
        XCTAssertFalse(
            code.contains(".textSelection"),
            "selecting wrappable text copies its zero-width spaces (#1589)"
        )
        XCTAssertTrue(
            code.contains("copyToPasteboard(preview)"),
            "the copy action must hand over the raw address, not the wrappable one (#1589)"
        )
    }

    /// Rule 3 (#1605): on macOS the preview reports the height its lines
    /// need. Without it the `MacSheetForm` row proposed one line's height and
    /// an 82-character address drew `…probe0915.cabal-…` at 406x12, the whole
    /// mail domain past the ellipsis; with it the same address drew 412x26
    /// across two lines.
    func testThePreviewWrapsOnMacOSInsteadOfTruncating() throws {
        let code = Self.code(in: try Self.sheetSource())
        let preview = try XCTUnwrap(
            Self.functionBody(named: "addressPreview", in: code),
            "addressPreview(_:) not found in \(Self.path)"
        )
        XCTAssertTrue(
            preview.contains(".fixedSize(horizontal: false, vertical: true)"),
            "the macOS preview row proposes one line's height and truncates the address (#1605)"
        )
    }

    /// The detector on synthetic snippets, so a rewrite of the view can't
    /// make the scan above vacuous.
    func testDetectorCatchesTheReportedShape() throws {
        XCTAssertEqual(try Self.rawPreviewHits(in: "Text(preview)"), 1)
        XCTAssertEqual(try Self.rawPreviewHits(in: "Text( preview )\n    .font(.caption)"), 1)
        XCTAssertEqual(try Self.rawPreviewHits(in: "Text(AddressDisplay.wrappable(preview))"), 0)
        XCTAssertEqual(try Self.rawPreviewHits(in: "Text(errorMessage)"), 0)
        XCTAssertEqual(try Self.rawPreviewHits(in: Self.code(in: "/// was Text(preview)")), 0)
        let twoFunctions = """
        private func addressPreview(_ preview: String) -> some View {
            Text(preview)
        }
        @ViewBuilder
        private var addressRow: some View {
            Text("x").fixedSize(horizontal: false, vertical: true)
        }
        """
        let body = try XCTUnwrap(Self.functionBody(named: "addressPreview", in: twoFunctions))
        XCTAssertFalse(body.contains(".fixedSize"), "the body must stop at the next declaration")
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheSourceIsReadable() throws {
        let source = try Self.sheetSource()
        XCTAssertTrue(
            source.contains("struct NewAddressSheet: View"),
            "\(Self.path) did not load"
        )
    }

    // MARK: - Corpus

    /// The text of `func <name>(` up to the next `func ` or `var ` declaration.
    private static func functionBody(named name: String, in code: String) -> String? {
        guard let start = code.range(of: "func \(name)(") else { return nil }
        let rest = code[start.upperBound...]
        let end = rest.range(of: #"\n\s*(private |fileprivate )?(func|var) "#, options: .regularExpression)
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    /// `Text(preview)`: the expression the sheet holds a whole address in.
    private static func rawPreviewHits(in body: String) throws -> Int {
        try body.ranges(of: Regex(#"\bText\(\s*preview\s*\)"#)).count
    }

    /// `body` with line comments cut.
    private static func code(in body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    private static func sheetSource() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(contentsOf: apple.appendingPathComponent(path), encoding: .utf8)
    }
}
