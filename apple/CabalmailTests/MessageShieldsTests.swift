import XCTest
import CabalmailKit
@testable import CabalmailUI

// The mail store's one record of writes in flight (`MessageShields`), which
// replaced the list's own pending sets and the reader's: every writer
// brackets its write there, and every merge and STATUS writer asks it.
@MainActor
final class MessageShieldsTests: XCTestCase {
    private let inbox = MessageRef(folder: "INBOX", uid: 4)
    private let other = MessageRef(folder: "INBOX", uid: 5)
    private let archive = MessageRef(folder: "Archive", uid: 4)

    // MARK: - Removals

    /// A reader's bracket and a list's can overlap on one message: it stays
    /// in flight until both end.
    func testARemovalStaysInFlightUntilEveryWriterEndsIt() {
        let shields = MessageShields()

        shields.setMoveInFlight(inbox, inFlight: true)
        shields.beginRemoval([inbox, other])
        shields.setMoveInFlight(inbox, inFlight: false)

        XCTAssertTrue(shields.isRemoving(inbox), "the list's removal still holds it")
        XCTAssertEqual(shields.pendingMoveRefs, [inbox, other])
        XCTAssertTrue(shields.hasRemovalInFlight(folderPath: "INBOX"))
        XCTAssertFalse(shields.hasRemovalInFlight(folderPath: "Archive"), "folder-keyed")

        shields.endRemoval([inbox, other])
        XCTAssertFalse(shields.isRemoving(inbox))
        XCTAssertEqual(shields.pendingMoveRefs, [])
    }

    func testEndingARemovalThatWasNeverBegunChangesNothing() {
        let shields = MessageShields()
        shields.beginRemoval([inbox])

        shields.endRemoval([archive])
        shields.setMoveInFlight(other, inFlight: false)

        XCTAssertEqual(shields.pendingMoveRefs, [inbox])
    }

    // MARK: - Flag writes

    func testAFlagWriteShieldsItsRowUntilItEnds() {
        let shields = MessageShields()

        shields.beginFlagWrite([inbox], flag: .seen, added: true)
        shields.beginFlagWrite([inbox], flag: .flagged, added: true)
        XCTAssertTrue(shields.isWritingFlags(inbox))
        XCTAssertEqual(shields.pendingFlagWriteRefs, [inbox])

        shields.endFlagWrite([inbox], flag: .seen, added: true)
        XCTAssertTrue(shields.isWritingFlags(inbox), "the \\Flagged write is still out")
        shields.endFlagWrite([inbox], flag: .flagged, added: true)
        XCTAssertFalse(shields.isWritingFlags(inbox))
        XCTAssertFalse(shields.isWritingFlags(other))
    }

    /// The reader's old bracket names no flag: it shields the row and says
    /// nothing about counts.
    func testAFlagWriteThatNamesNoFlagShieldsWithoutBoundingCounts() {
        let shields = MessageShields()
        let askedAt = ContinuousClock.now

        shields.setFlagWrite(inbox, inFlight: true)
        XCTAssertTrue(shields.isWritingFlags(inbox))
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: askedAt), .free)

        shields.setFlagWrite(inbox, inFlight: false)
        XCTAssertFalse(shields.isWritingFlags(inbox))
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: askedAt), .free)
    }

    // MARK: - Count bounds (#1880)

    func testAMarkReadInFlightLetsAStatusLowerTheUnreadCountButNotRaiseIt() {
        let shields = MessageShields()
        let askedAt = ContinuousClock.now

        shields.beginFlagWrite([inbox], flag: .seen, added: true)

        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: askedAt), .lowerOnly)
        XCTAssertEqual(shields.unreadBound(folderPath: "Archive", askedAt: askedAt), .free, "folder-keyed")
        XCTAssertEqual(shields.flaggedBound(folderPath: "INBOX", askedAt: askedAt), .free)
    }

    func testAMarkUnreadInFlightLetsItRaiseTheCountButNotLowerIt() {
        let shields = MessageShields()
        shields.beginFlagWrite([inbox], flag: .seen, added: false)

        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: .now), .raiseOnly)
    }

    func testWritesBothWaysHoldTheCount() {
        let shields = MessageShields()
        shields.beginFlagWrite([inbox], flag: .seen, added: true)
        shields.beginFlagWrite([other], flag: .seen, added: false)

        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: .now), .held)
    }

    /// A STATUS asked before a mark-read landed may not count it, though the
    /// write has since ended.
    func testAWriteThatEndedAfterTheStatusWasAskedStillBoundsIt() {
        let shields = MessageShields()
        let start = ContinuousClock.now
        shields.beginFlagWrite([inbox], flag: .seen, added: true)
        shields.endFlagWrite([inbox], flag: .seen, added: true, at: start + .seconds(2))

        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start), .lowerOnly)
        XCTAssertEqual(
            shields.unreadBound(folderPath: "INBOX", askedAt: start + .seconds(3)), .free,
            "a STATUS asked after the write ended counts it"
        )
    }

    func testAnEndedWriteIsForgottenAfterTheWindow() {
        let shields = MessageShields()
        let start = ContinuousClock.now
        shields.beginFlagWrite([inbox], flag: .seen, added: true)
        shields.endFlagWrite([inbox], flag: .seen, added: true, at: start)
        shields.beginFlagWrite([other], flag: .flagged, added: true)

        shields.endFlagWrite([other], flag: .flagged, added: true, at: start + MessageShields.confirmedRemovalWindow)

        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start - .seconds(1)), .free)
        XCTAssertEqual(shields.flaggedBound(folderPath: "INBOX", askedAt: start - .seconds(1)), .raiseOnly)
    }

    func testARemovalInFlightOrConfirmedSinceLowersBothCounts() {
        let shields = MessageShields()
        let start = ContinuousClock.now
        shields.beginRemoval([inbox])
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start), .lowerOnly)
        XCTAssertEqual(shields.flaggedBound(folderPath: "INBOX", askedAt: start), .lowerOnly)

        shields.endRemoval([inbox])
        shields.recordConfirmedRemovals([inbox], at: start + .seconds(1))
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start), .lowerOnly)
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start + .seconds(2)), .free)
    }

    func testFlaggingRaisesTheFlaggedBoundAndUnflaggingLowersIt() {
        let shields = MessageShields()
        shields.beginFlagWrite([inbox], flag: .flagged, added: true)
        XCTAssertEqual(shields.flaggedBound(folderPath: "INBOX", askedAt: .now), .raiseOnly)
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: .now), .free)

        shields.beginFlagWrite([other], flag: .flagged, added: false)
        XCTAssertEqual(shields.flaggedBound(folderPath: "INBOX", askedAt: .now), .held)
    }

    func testABoundKeepsACountFromMovingAgainstIt() {
        XCTAssertEqual(CountBound.free.bound(5, from: 3), 5)
        XCTAssertEqual(CountBound.lowerOnly.bound(5, from: 3), 3)
        XCTAssertEqual(CountBound.lowerOnly.bound(2, from: 3), 2)
        XCTAssertEqual(CountBound.raiseOnly.bound(2, from: 3), 3)
        XCTAssertEqual(CountBound.raiseOnly.bound(5, from: 3), 5)
        XCTAssertEqual(CountBound.held.bound(5, from: 3), 3)
        XCTAssertEqual(CountBound.held.bound(1, from: 3), 3)
    }

    // MARK: - Sign-out

    func testTheResetForgetsEveryWriteAndEndedWrite() {
        let shields = MessageShields()
        let start = ContinuousClock.now
        shields.beginRemoval([inbox])
        shields.beginFlagWrite([other], flag: .seen, added: true)
        shields.beginFlagWrite([archive], flag: .seen, added: false)
        shields.endFlagWrite([archive], flag: .seen, added: false, at: start + .seconds(1))
        shields.recordConfirmedRemovals([archive], at: start)
        shields.beginArrival(into: "Projects")
        shields.beginArrival(into: "Lists")
        shields.endArrival(into: "Lists", at: start + .seconds(1))

        shields.reset()

        XCTAssertEqual(shields.pendingMoveRefs, [])
        XCTAssertEqual(shields.pendingFlagWriteRefs, [])
        XCTAssertEqual(shields.confirmedRemovals, [:])
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start), .free)
        XCTAssertEqual(shields.unreadBound(folderPath: "Archive", askedAt: start), .free)
        XCTAssertEqual(shields.unreadBound(folderPath: "Projects", askedAt: start), .free)
        XCTAssertEqual(shields.unreadBound(folderPath: "Lists", askedAt: start), .free)
        // A late end from the last account's reader or move records nothing.
        shields.endFlagWrite([other], flag: .seen, added: true, at: start + .seconds(2))
        shields.endArrival(into: "Projects", at: start + .seconds(2))
        XCTAssertEqual(shields.unreadBound(folderPath: "INBOX", askedAt: start), .free)
        XCTAssertEqual(shields.unreadBound(folderPath: "Projects", askedAt: start), .free)
    }
}
