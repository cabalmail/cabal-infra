import XCTest
@testable import Cabalmail

// Regression coverage for issue #1343: the bulk action bar draws inside the
// message-list column, which on macOS is 220 pt until the window passes
// ~1000 pt wide. Nothing constrained the captions at that width, so SwiftUI
// squeezed the row by hyphenating each one — "Ar-chive", "Mov e…", "Rea d"
// and a four-line "2 se-lect-ed". The bar now offers `ViewThatFits` a ladder
// of progressively narrower rows and keeps every caption on one line, so a
// column too narrow for the full bar drops an element instead of a syllable.
final class BulkActionBarLayoutTests: XCTestCase {

    // MARK: - The ladder

    /// `ViewThatFits` takes the first candidate that fits, so a rung that is
    /// not strictly narrower than the one before it can never be reached —
    /// and a rung that is *wider* would shadow everything after it.
    func testLadderShedsContentAndNeverAddsItBack() {
        let ladder = BulkActionBarLayout.allCases
        XCTAssertEqual(ladder.count, 3)

        for (narrower, wider) in zip(ladder.dropFirst(), ladder) {
            XCTAssertLessThan(
                Self.drawnElements(narrower),
                Self.drawnElements(wider),
                "\(narrower) must draw strictly less than \(wider) or ViewThatFits can never pick it"
            )
            XCTAssertFalse(
                narrower.showsCount && !wider.showsCount,
                "\(narrower) puts the count back after \(wider) dropped it"
            )
            XCTAssertFalse(
                narrower.showsCaptions && !wider.showsCaptions,
                "\(narrower) puts the captions back after \(wider) dropped them"
            )
        }
    }

    /// The widest rung is the bar as it has always looked, so nothing changes
    /// where it already fit — iPhone, and a message-list column at 300 pt.
    func testWidestRungIsTodaysBar() {
        XCTAssertEqual(BulkActionBarLayout.allCases.first, .full)
        XCTAssertTrue(BulkActionBarLayout.full.showsCount)
        XCTAssertTrue(BulkActionBarLayout.full.showsCaptions)
    }

    /// The captions outlive the count: a bar whose glyphs are unlabelled is
    /// the last resort, and the count has a second home in the reader pane's
    /// "N Messages Selected" and in every button's accessibility label.
    func testCountIsShedBeforeTheCaptions() {
        XCTAssertEqual(BulkActionBarLayout.captionsOnly.showsCount, false)
        XCTAssertEqual(BulkActionBarLayout.captionsOnly.showsCaptions, true)
        XCTAssertEqual(BulkActionBarLayout.glyphsOnly.showsCaptions, false)
    }

    // MARK: - The bar wires the whole ladder up

    /// The ladder only helps if the bar actually offers every rung, in order,
    /// to a horizontal `ViewThatFits`. Nothing else can see that: a rung left
    /// out of the candidate list still type-checks and still passes the
    /// invariants above.
    func testBarOffersEveryRungToViewThatFitsInOrder() throws {
        let source = try Self.barSource()
        XCTAssertTrue(
            source.contains("ViewThatFits(in: .horizontal)"),
            "the bar must pick its row by width, not draw one unconditionally"
        )
        XCTAssertEqual(
            Self.candidateLayouts(in: source),
            BulkActionBarLayout.allCases.map { String(describing: $0) },
            "every layout case must be a ViewThatFits candidate, widest first"
        )
    }

    /// The caption is what hyphenated, and `.fixedSize` is what stops it —
    /// both for the user (no "Ar-chive") and for `ViewThatFits`, which reads
    /// the caption's natural width to decide whether a rung fits at all.
    func testEveryCaptionIsPinnedToOneLine() throws {
        XCTAssertTrue(
            Self.captionIsPinned(in: try Self.barSource()),
            "the bulk action button's caption may not wrap or hyphenate (#1343)"
        )
    }

    // MARK: - Detector self-tests

    /// Proves the two scans see the reported shape as broken and the fix as
    /// fixed, so neither assertion above can pass vacuously after a rewrite.
    func testDetectorsSeeThePreFixAndPostFixShapes() {
        let broken = """
        VStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(label)
                .font(.caption2)
        }
        """
        let fixed = """
        VStack(spacing: 2) {
            Image(systemName: systemImage)
            if showsCaption {
                Text(label)
                    .font(.caption2)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        """
        XCTAssertFalse(Self.captionIsPinned(in: broken))
        XCTAssertTrue(Self.captionIsPinned(in: fixed))

        let oneRung = """
        HStack(spacing: 14) {
            bulkActionRow(model: model, count: count, layout: .full)
        }
        """
        XCTAssertEqual(Self.candidateLayouts(in: oneRung), ["full"])
        XCTAssertNotEqual(
            Self.candidateLayouts(in: oneRung),
            BulkActionBarLayout.allCases.map { String(describing: $0) }
        )
    }

    // MARK: - Extraction

    /// How much a rung draws, as a count of shed-able elements. Only used to
    /// order the rungs against each other.
    private static func drawnElements(_ layout: BulkActionBarLayout) -> Int {
        (layout.showsCount ? 1 : 0) + (layout.showsCaptions ? 1 : 0)
    }

    /// The `layout:` argument of every `bulkActionRow` call, in source order.
    private static func candidateLayouts(in source: String) -> [String] {
        var found: [String] = []
        var search = source.startIndex
        while let call = source.range(of: "bulkActionRow(", range: search..<source.endIndex) {
            search = call.upperBound
            guard let marker = source.range(of: "layout: .", range: call.upperBound..<source.endIndex),
                  let close = source.range(of: ")", range: marker.upperBound..<source.endIndex)
            else { continue }
            found.append(String(source[marker.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return found
    }

    /// True when the caption `Text` is followed, before its enclosing view
    /// ends, by the modifier that keeps it on one line.
    private static func captionIsPinned(in source: String) -> Bool {
        guard let caption = source.range(of: "Text(label)") else { return false }
        let tail = source[caption.upperBound...]
            .prefix(while: { $0 != "}" })
        return tail.contains(".fixedSize(horizontal: true")
    }

    private static func barSource() throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        return try String(
            contentsOf: apple.appendingPathComponent("Cabalmail/Views/MessageListView+Bulk.swift"),
            encoding: .utf8
        )
    }
}
