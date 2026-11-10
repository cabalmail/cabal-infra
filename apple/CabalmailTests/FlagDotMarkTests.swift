import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a mail row, a feed row and the reader's chips draw for an item's
/// flags (`FlagDotMark`): the system flag as one more palette entry, in
/// palette order, under the palette's names and colors
/// (`docs/1.x/unified-flags-plan.md`, decision 4).
final class FlagDotMarkTests: XCTestCase {
    private func entry(
        _ slot: String, _ label: String, _ color: String, enabled: Bool = true
    ) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color, enabled: enabled)
    }

    private var palette: [FlagPaletteEntry] {
        [entry("cabal-flag-01", "Later", "teal"), entry("cabal-flag-02", "Waiting", "blue")]
    }

    private func system(_ label: String = "Flagged", _ color: String = "yellow") -> FlagDotMark {
        FlagDotMark(slot: FlagPalette.systemSlot, label: label, color: color)
    }

    // MARK: - Mail

    func testAFlaggedMessageDrawsTheDefaultEntryWhenThePaletteStoresNone() {
        XCTAssertEqual(FlagDotMark.marks(for: [.seen, .flagged], palette: []), [system()])
        XCTAssertEqual(FlagDotMark.marks(for: [.seen, .flagged], palette: palette), [system()])
    }

    func testAnUnflaggedMessageDrawsNothingForTheSystemFlag() {
        XCTAssertEqual(FlagDotMark.marks(for: [.seen, .answered], palette: palette), [])
        XCTAssertEqual(
            FlagDotMark.marks(for: [.keyword("cabal-flag-02")], palette: palette),
            [FlagDotMark(slot: "cabal-flag-02", label: "Waiting", color: "blue")]
        )
    }

    func testTheSystemFlagTakesItsStoredNameAndColor() {
        let stored = [entry(FlagPalette.systemSlot, "Urgent", "red")] + palette
        XCTAssertEqual(FlagDotMark.marks(for: [.flagged], palette: stored), [system("Urgent", "red")])
    }

    func testMarksFollowPaletteOrderNotSlotOrder() {
        let stored = [palette[1], entry(FlagPalette.systemSlot, "Urgent", "red"), palette[0]]
        let flags: Set<Flag> = [.flagged, .keyword("cabal-flag-01"), .keyword("cabal-flag-02")]
        XCTAssertEqual(
            FlagDotMark.marks(for: flags, palette: stored).map(\.slot),
            ["cabal-flag-02", FlagPalette.systemSlot, "cabal-flag-01"]
        )
        // With nothing stored for it, the system flag leads.
        XCTAssertEqual(
            FlagDotMark.marks(for: flags, palette: palette).map(\.slot),
            [FlagPalette.systemSlot, "cabal-flag-01", "cabal-flag-02"]
        )
    }

    func testTheRowCapCountsTheSystemFlag() {
        let stored = (1...6).map { entry(String(format: "cabal-flag-%02d", $0), "F\($0)", "blue") }
        let flags = Set(stored.map { Flag.keyword($0.slot) }).union([.flagged])
        let marks = FlagDotMark.marks(for: flags, palette: stored)
        XCTAssertEqual(marks.count, FlagDotMark.rowLimit)
        XCTAssertEqual(
            marks.map(\.slot),
            [FlagPalette.systemSlot, "cabal-flag-01", "cabal-flag-02", "cabal-flag-03"]
        )
        // The reader's chips take every flag.
        XCTAssertEqual(FlagDotMark.marks(for: flags, palette: stored, limit: .max).count, 7)
    }

    func testADisabledEntrysFlagIsStillDrawn() {
        // A tag outlives being offered, for the system flag as for a
        // custom one.
        let stored = [
            entry(FlagPalette.systemSlot, "Flagged", "yellow", enabled: false),
            entry("cabal-flag-01", "Later", "teal", enabled: false),
        ]
        XCTAssertEqual(
            FlagDotMark.marks(for: [.flagged, .keyword("cabal-flag-01")], palette: stored).map(\.label),
            ["Flagged", "Later"]
        )
    }

    func testATagWhoseEntryWasDeletedIsNamedByItsSlotAndDrawnLast() {
        let marks = FlagDotMark.marks(
            for: [.flagged, .keyword("cabal-flag-09"), .keyword("cabal-flag-01")], palette: palette
        )
        XCTAssertEqual(marks.map(\.slot), [FlagPalette.systemSlot, "cabal-flag-01", "cabal-flag-09"])
        XCTAssertEqual(marks.last, FlagDotMark(slot: "cabal-flag-09", label: "cabal-flag-09", color: ""))
    }

    // MARK: - Feeds

    func testAFlaggedFeedItemDrawsTheSystemEntry() {
        XCTAssertEqual(FlagDotMark.marks(isFlagged: true, palette: palette), [system()])
        XCTAssertEqual(FlagDotMark.marks(isFlagged: false, palette: palette), [])
        // The same entry a flagged message draws, renamed and recolored.
        let stored = palette + [entry(FlagPalette.systemSlot, "Read later", "purple")]
        XCTAssertEqual(
            FlagDotMark.marks(isFlagged: true, palette: stored),
            FlagDotMark.marks(for: [.flagged], palette: stored)
        )
        XCTAssertEqual(FlagDotMark.marks(isFlagged: true, palette: stored), [system("Read later", "purple")])
    }

    func testTheFeedRowSaysItsFlagByName() {
        XCTAssertEqual(
            FeedItemRow.accessibilityLabel(
                isRead: false, title: "Title", snippet: "First line", date: "2h", flags: ["Read later"]
            ),
            "Unread, Title, First line, 2h, Read later"
        )
        XCTAssertEqual(
            FeedItemRow.accessibilityLabel(isRead: true, title: "Title", snippet: "", date: "2h", flags: []),
            "Title, 2h"
        )
    }
}
