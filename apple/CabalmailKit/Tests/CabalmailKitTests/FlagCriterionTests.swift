import XCTest
@testable import CabalmailKit

/// `FlagCriterion.matches`: the rule a list applies to the rows it holds
/// while it is narrowed to one flag or to any flag.
final class FlagCriterionTests: XCTestCase {
    private let later = "cabal-flag-03"
    private let work = "cabal-flag-05"

    func testASlotMatchesOnlyItemsCarryingThatFlag() {
        let criterion = FlagCriterion.slot(later)

        XCTAssertTrue(criterion.matches([.keyword(later)]))
        XCTAssertTrue(criterion.matches([.seen, .flagged, .keyword(later), .keyword(work)]))
        XCTAssertFalse(criterion.matches([.keyword(work)]))
        XCTAssertFalse(criterion.matches([.flagged]), "the built-in flag is not this flag")
        XCTAssertFalse(criterion.matches([]))
    }

    func testTheBuiltInFlagsSlotMatchesTheSystemFlag() {
        let criterion = FlagCriterion.slot(FlagPalette.systemSlot)

        XCTAssertTrue(criterion.isSystemFlag)
        XCTAssertNil(criterion.keywordSlot)
        XCTAssertTrue(criterion.matches([.flagged]))
        XCTAssertFalse(criterion.matches([.keyword(later)]), "a custom flag is not the built-in one")
        XCTAssertFalse(criterion.matches([.seen]))
    }

    func testAnyMatchesTheBuiltInFlagAndEveryPaletteSlot() {
        XCTAssertTrue(FlagCriterion.any.matches([.flagged]))
        for slot in FlagPalette.slots {
            XCTAssertTrue(FlagCriterion.any.matches([.seen, .keyword(slot)]), slot)
        }
        XCTAssertFalse(FlagCriterion.any.isSystemFlag)
        XCTAssertNil(FlagCriterion.any.keywordSlot)
    }

    /// A message carries keywords the palette never wrote. None of them is a
    /// flag: under "any flag" such a message would otherwise be listed with
    /// no dot to say why.
    func testAnyIgnoresKeywordsThatAreNotPaletteSlots() {
        XCTAssertFalse(FlagCriterion.any.matches([]))
        XCTAssertFalse(FlagCriterion.any.matches([.seen, .answered, .draft]))
        XCTAssertFalse(FlagCriterion.any.matches([.keyword("$Forwarded"), .keyword("NonJunk")]))
        XCTAssertFalse(FlagCriterion.any.matches([.keyword("cabal-flag-21")]), "there are twenty slots")
    }

    func testAStringThatIsNoSlotMatchesNothing() {
        let criterion = FlagCriterion.slot("$Forwarded")

        XCTAssertNil(criterion.keywordSlot)
        XCTAssertFalse(criterion.matches([.keyword("$Forwarded")]))
    }
}
