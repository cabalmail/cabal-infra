import XCTest
import CabalmailKit
@testable import Cabalmail

/// `ReaderOptionMenuPolicy`: what the reader's mark-read and dispose option
/// menus offer, and the identity that makes macOS redraw them (#1337 — the
/// same retained-AppKit-menu mechanism #1329 measured on the flag menu,
/// verified on these two surfaces on macOS 26.6.2).
final class ReaderOptionMenuPolicyTests: XCTestCase {
    private func seen(
        _ advance: MarkReadAdvance, isSeen: Bool = false
    ) -> [ReaderMenuRow<MarkReadAdvance>] {
        ReaderOptionMenuPolicy.seenRows(advance: advance, isSeen: isSeen)
    }

    private func dispose(
        action: DisposeAction,
        advance: DisposeAdvance,
        verbs: [(action: DisposeAction, verb: String)] = [
            (action: .archive, verb: "Archive"), (action: .trash, verb: "Delete"),
        ]
    ) -> [ReaderMenuRow<DisposeOption>] {
        ReaderOptionMenuPolicy.disposeRows(
            verbs: verbs, selectedAction: action, selectedAdvance: advance
        )
    }

    // MARK: - Mark-read rows

    func testSeenOffersEveryAdvanceInOrderAndChecksTheCurrentDefault() {
        let rows = seen(.nextUnread)
        XCTAssertEqual(rows.map(\.option), MarkReadAdvance.allCases)
        XCTAssertEqual(rows.map(\.isOn), [false, true, false, false])
        XCTAssertEqual(
            rows.map(\.label),
            [
                "Mark Read and Stay Here",
                "Mark Read and Move to Next Unread",
                "Mark Read and Move to Previous Unread",
                "Mark Read and Move to First Unread",
            ]
        )
    }

    func testSeenRowsAreDisabledOnceTheMessageIsSeen() {
        XCTAssertEqual(seen(.stay, isSeen: false).map(\.isEnabled), [true, true, true, true])
        XCTAssertEqual(seen(.stay, isSeen: true).map(\.isEnabled), [false, false, false, false])
    }

    // MARK: - Dispose rows

    func testDisposeOffersEveryActionAdvancePairGroupedByAction() {
        let rows = dispose(action: .trash, advance: .nextUnread)
        XCTAssertEqual(rows.count, DisposeAction.allCases.count * DisposeAdvance.allCases.count)
        XCTAssertEqual(rows.map(\.option.action), Array(repeating: .archive, count: 4)
            + Array(repeating: .trash, count: 4))
        // Exactly one divider, before the first row of the second action.
        XCTAssertEqual(rows.map(\.startsGroup).filter { $0 }.count, 1)
        XCTAssertTrue(rows[4].startsGroup)
        XCTAssertFalse(rows[0].startsGroup)
    }

    func testDisposeChecksOnlyTheCurrentPair() {
        let rows = dispose(action: .trash, advance: .previousUnread)
        let checked = rows.filter(\.isOn).map(\.option)
        XCTAssertEqual(checked, [DisposeOption(action: .trash, advance: .previousUnread)])
    }

    /// The verb comes from the reconciled intent, so inside Trash the
    /// trash rows read "Delete Forever" and inside Archive the archive rows
    /// read "Restore" — and the identity is built from the same string.
    func testDisposeLabelsUseTheReconciledVerb() {
        let rows = dispose(
            action: .trash, advance: .next,
            verbs: [(action: .archive, verb: "Restore"), (action: .trash, verb: "Delete Forever")]
        )
        XCTAssertEqual(rows.first?.label, "Restore and Move to Next Message")
        XCTAssertEqual(rows[4].label, "Delete Forever and Move to Next Message")
    }

    // MARK: - Identity

    /// The reported defect on the mark-read menu: choosing an option from
    /// the menu itself must replace the menu, or the checkmark stays on the
    /// row that was current when the menu was first opened.
    func testSeenIdentityChangesWhenTheCheckedRowMoves() {
        XCTAssertNotEqual(
            ReaderOptionMenuPolicy.identity(seen(.nextUnread)),
            ReaderOptionMenuPolicy.identity(seen(.stay))
        )
    }

    /// Measured alongside the checkmark: the rows kept drawing *enabled*
    /// after the open message became seen, so the disabled state is part of
    /// what the identity has to cover.
    func testSeenIdentityChangesWhenTheRowsBecomeDisabled() {
        XCTAssertNotEqual(
            ReaderOptionMenuPolicy.identity(seen(.stay, isSeen: false)),
            ReaderOptionMenuPolicy.identity(seen(.stay, isSeen: true))
        )
    }

    /// The dispose menu's measured arm: the pair changed in Settings with
    /// the reader still open.
    func testDisposeIdentityChangesWhenTheCheckedPairMoves() {
        XCTAssertNotEqual(
            ReaderOptionMenuPolicy.identity(dispose(action: .trash, advance: .nextUnread)),
            ReaderOptionMenuPolicy.identity(dispose(action: .archive, advance: .nextUnread))
        )
        XCTAssertNotEqual(
            ReaderOptionMenuPolicy.identity(dispose(action: .trash, advance: .nextUnread)),
            ReaderOptionMenuPolicy.identity(dispose(action: .trash, advance: .next))
        )
    }

    /// Moving between folders changes the verbs without changing the
    /// checked pair, and a frozen menu keeps its row titles too.
    func testDisposeIdentityChangesWhenTheVerbsChange() {
        XCTAssertNotEqual(
            ReaderOptionMenuPolicy.identity(dispose(action: .trash, advance: .next)),
            ReaderOptionMenuPolicy.identity(dispose(
                action: .trash, advance: .next,
                verbs: [
                    (action: .archive, verb: "Restore"),
                    (action: .trash, verb: "Delete Forever"),
                ]
            ))
        )
    }

    /// The other half of the contract: an identity that churned on every
    /// body pass would rebuild the menu constantly, so equal content must
    /// give an equal key.
    func testIdentityIsStableForUnchangedContent() {
        XCTAssertEqual(
            ReaderOptionMenuPolicy.identity(seen(.firstUnread, isSeen: true)),
            ReaderOptionMenuPolicy.identity(seen(.firstUnread, isSeen: true))
        )
        XCTAssertEqual(
            ReaderOptionMenuPolicy.identity(dispose(action: .archive, advance: .firstUnread)),
            ReaderOptionMenuPolicy.identity(dispose(action: .archive, advance: .firstUnread))
        )
    }

    /// A row's fields are separated by control characters no label can
    /// plausibly carry, so two different menus cannot share a key by
    /// running their fields together.
    func testRowsThatDifferOnlyByFieldBoundaryDoNotCollide() {
        let left = [ReaderMenuRow(option: "a", key: "a", label: "b", isOn: false)]
        let right = [ReaderMenuRow(option: "ab", key: "ab", label: "", isOn: false)]
        XCTAssertNotEqual(
            ReaderOptionMenuPolicy.identity(left),
            ReaderOptionMenuPolicy.identity(right)
        )
    }

    /// The flag menu's identity is the same rule, and there is only one
    /// implementation of it — a second copy is what left these two menus
    /// broken after #1329 fixed that one.
    func testFlagMenuIdentityStillDistinguishesACheckedRow() {
        let palette = [
            FlagPaletteEntry(slot: "cabal-flag-01", label: "Alpha", color: "blue"),
            FlagPaletteEntry(slot: "cabal-flag-02", label: "Beta", color: "teal"),
        ]
        XCTAssertNotEqual(
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(palette: palette, taggedSlots: [])),
            FlagMenuPolicy.identity(
                FlagMenuPolicy.rows(palette: palette, taggedSlots: ["cabal-flag-02"])
            )
        )
    }
}
