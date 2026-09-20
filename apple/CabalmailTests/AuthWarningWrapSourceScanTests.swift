import XCTest

// Regression coverage for #1637.
//
// The reader header's authentication warning is the one sentence that tells
// the reader a message may not be from who it claims. It needs about 480 pt
// to set on one line, so every reader pane narrower than that has to wrap
// it — and it did not. UIKit sized the `Label` from its text's *unwrapped*
// ideal, one line's height, stretched that line to the width available and
// truncated the rest with an ellipsis. Measured on an iPhone 17 at a 402 pt
// pane against the same message in both arms:
//
//   pre-fix   {{69.3, 260.3}, {295.7, 14.3}}   one line, "…as co…"
//   post-fix  {{69.3, 260.3}, {272.0, 30.3}}   two lines
//
// `.fixedSize(horizontal: false, vertical: true)` on the label is the whole
// fix, and this scan is its only automated guard, because **the defect has
// no hosting-controller seam**. Three arms said so before this file was
// written, each with and without the modifier:
//
//   - `NSHostingController.sizeThatFits` over the bare label: identical at
//     200 / 272 / 295.7 / 364 / 480 pt.
//   - the same, over the header's real shape (avatar, sender line, chips,
//     zero-min `Spacer`): identical at 300 / 340 / 402 / 440 pt.
//   - `UIHostingController.sizeThatFits` on an iOS host: 30.33 pt both ways
//     at 295.7 pt, i.e. the pre-fix arm wraps there and the detector is dead.
//
// Both layout engines ask the label what height it would like and get the
// wrapped answer either way; only the real header's layout proposes the
// stretched width that produces the defect. So what can be asserted here is
// that the modifier is present and applies to this label — reverting it
// fails `testTheWarningTakesItsWrappedHeight` by name.
final class AuthWarningWrapSourceScanTests: XCTestCase {

    private static let path = "Cabalmail/Views/AuthResultsLine.swift"

    /// The rule: the warning label asks for the height its wrapped text
    /// needs. `horizontal: true` would be a different (and wrong) view — it
    /// would let the sentence run past the pane rather than wrap in it.
    func testTheWarningTakesItsWrappedHeight() throws {
        let code = Self.code(in: try Self.viewSource())
        XCTAssertEqual(
            Self.verticalFixedSizeHits(in: code), 1,
            """
            AuthWarningLabel's Label must carry \
            .fixedSize(horizontal: false, vertical: true), or UIKit truncates \
            the sentence to one line in any pane under ~480 pt (#1637)
            """
        )
        XCTAssertEqual(
            Self.horizontalFixedSizeHits(in: code), 0,
            "fixing the horizontal axis would push the sentence out of the pane (#1637)"
        )
    }

    /// The modifier has to sit on the warning label itself. The chips above
    /// it are a sibling in the same `VStack`, and a `fixedSize` that landed
    /// on those instead would read as present here while the sentence went
    /// on truncating.
    func testTheModifierIsOnTheWarningLabel() throws {
        let body = try Self.warningLabelBody()
        XCTAssertEqual(
            Self.verticalFixedSizeHits(in: Self.code(in: body)), 1,
            "the fixedSize must be inside AuthWarningLabel's body, not on a sibling (#1637)"
        )
    }

    /// The detector on synthetic snippets, so a later rewrite of the view
    /// cannot make the assertions above vacuous.
    func testDetectorCatchesTheReportedShapes() {
        XCTAssertEqual(Self.verticalFixedSizeHits(in: ".fixedSize(horizontal: false, vertical: true)"), 1)
        XCTAssertEqual(Self.verticalFixedSizeHits(in: ".fixedSize(horizontal:false,vertical:true)"), 1)
        XCTAssertEqual(Self.verticalFixedSizeHits(in: ".fixedSize(horizontal: false, vertical: false)"), 0)
        XCTAssertEqual(Self.verticalFixedSizeHits(in: ".fixedSize()"), 0)
        XCTAssertEqual(Self.verticalFixedSizeHits(in: ".lineLimit(nil)"), 0)
        XCTAssertEqual(Self.horizontalFixedSizeHits(in: ".fixedSize(horizontal: true, vertical: true)"), 1)
        XCTAssertEqual(Self.horizontalFixedSizeHits(in: ".fixedSize(horizontal: false, vertical: true)"), 0)
    }

    /// The trap this file was written around: the comment above the fix
    /// explains the rule and names the modifier, so a scan that did not cut
    /// line comments would pass on a file where the fix had been deleted.
    func testTheScanReadsCodeNotProse() {
        let reverted = """
        // Without the vertical .fixedSize(horizontal: false, vertical: true)
        // UIKit truncated this to one line.
        Label(AuthResultsLine.warningCopy, systemImage: "exclamationmark.shield.fill")
            .font(.caption)
        """
        XCTAssertEqual(
            Self.verticalFixedSizeHits(in: Self.code(in: reverted)), 0,
            "a comment naming the modifier is not a use of it"
        )
        XCTAssertEqual(
            Self.verticalFixedSizeHits(
                in: Self.code(in: ".fixedSize(horizontal: false, vertical: true) // #1637")
            ),
            1
        )
    }

    /// Floor: a mis-rooted read finds nothing and passes everything above.
    func testTheSourceIsReadable() throws {
        let source = try Self.viewSource()
        XCTAssertTrue(source.contains("struct AuthWarningLabel: View"), "\(Self.path) did not load")
        XCTAssertTrue(
            source.contains("AuthResultsLine.warningCopy"),
            "the warning sentence — what this scan is about — is missing from the source"
        )
    }

    // MARK: - Corpus

    private static func verticalFixedSizeHits(in body: String) -> Int {
        matches(body, #"\.fixedSize\(\s*horizontal:\s*false\s*,\s*vertical:\s*true\s*\)"#)
    }

    private static func horizontalFixedSizeHits(in body: String) -> Int {
        matches(body, #"\.fixedSize\(\s*horizontal:\s*true\s*,"#)
    }

    private static func matches(_ body: String, _ pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        return regex.numberOfMatches(in: body, range: NSRange(body.startIndex..., in: body))
    }

    /// `AuthWarningLabel`'s declaration through the end of the file — it is
    /// the last type in it, which the floor above pins.
    private static func warningLabelBody() throws -> String {
        let source = try viewSource()
        guard let start = source.range(of: "struct AuthWarningLabel: View") else {
            XCTFail("AuthWarningLabel is no longer declared in \(path)")
            return ""
        }
        return String(source[start.lowerBound...])
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
