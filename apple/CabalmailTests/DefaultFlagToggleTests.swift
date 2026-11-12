import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The one-press flag controls write the palette's default flag
/// (unified-flags plan, decision 5): the list's swipe and row menu
/// (`toggleDefaultFlag`), its selection menu, bulk bar and Cmd+Shift+8
/// (`setDefaultFlag`), and the reader's button and Cmd+Shift+L. Each test
/// reads what reached the server, so a control that still wrote `\Flagged`
/// for a reordered palette fails here.
@MainActor
final class DefaultFlagToggleTests: XCTestCase {
    private let todo = FlagPaletteEntry(slot: "cabal-flag-03", label: "Todo", color: "red")
    private let system = FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "Flagged", color: "yellow")

    private func preferences(_ palette: [FlagPaletteEntry]) -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.flagPalette = palette
        return preferences
    }

    private func makeList(
        imap: FakeImapClient, palette: [FlagPaletteEntry], envelopes: [Envelope]
    ) throws -> MessageListViewModel {
        let model = MessageListViewModel(
            folder: Folder(path: "INBOX", attributes: [], isSubscribed: true),
            client: try TestFixtures.makeClient(imap: imap),
            preferences: preferences(palette),
            mailStore: AppState().mailStore
        )
        model.envelopes = model.placedInFolder(envelopes)
        return model
    }

    private func makeReader(
        imap: FakeImapClient, palette: [FlagPaletteEntry], flags: Set<Flag> = []
    ) throws -> MessageDetailViewModel {
        MessageDetailViewModel(
            folder: Folder(path: "INBOX", attributes: [], isSubscribed: true),
            envelope: TestFixtures.makeEnvelope(uid: 7, flags: flags),
            client: try TestFixtures.makeClient(imap: imap),
            preferences: preferences(palette)
        )
    }

    private func ref(_ uid: UInt32) -> MessageRef { MessageRef(folder: "INBOX", uid: uid) }

    /// A palette as a build from before the Enabled switch was removed
    /// stored it: `enabled` on every entry, false on both.
    private func storedAsSwitchedOff() throws -> [FlagPaletteEntry] {
        try XCTUnwrap(FlagPalette.decode(
            #"[{"color":"red","enabled":false,"label":"Todo","slot":"cabal-flag-03"},"#
                + #"{"color":"yellow","enabled":false,"label":"Flagged","slot":"\\Flagged"}]"#
        ))
    }

    // MARK: - List rows

    func testAnUntouchedPaletteStillTogglesTheServersFlag() async throws {
        let imap = FakeImapClient()
        let model = try makeList(imap: imap, palette: [], envelopes: [TestFixtures.makeEnvelope(uid: 1)])

        await model.toggleDefaultFlag(model.envelopes[0])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.flagged]])
        XCTAssertEqual(calls.map(\.operation), [.add])
        XCTAssertTrue(model.envelopes[0].flags.contains(.flagged))
    }

    func testAFlagMovedToTheTopIsWhatTheRowToggleWrites() async throws {
        let imap = FakeImapClient()
        let model = try makeList(
            imap: imap, palette: [todo, system], envelopes: [TestFixtures.makeEnvelope(uid: 1)]
        )

        await model.toggleDefaultFlag(model.envelopes[0])
        XCTAssertEqual(model.envelopes[0].flags.contains(.keyword("cabal-flag-03")), true)
        XCTAssertFalse(model.envelopes[0].flags.contains(.flagged), "the server's flag is not the default any more")

        await model.toggleDefaultFlag(model.envelopes[0])
        XCTAssertFalse(model.envelopes[0].flags.contains(.keyword("cabal-flag-03")), "the second press clears it")

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.keyword("cabal-flag-03")], [.keyword("cabal-flag-03")]])
        XCTAssertEqual(calls.map(\.operation), [.add, .remove])
    }

    /// A flag cannot be switched off, so a palette a build from before
    /// that stored with every entry `enabled: false` still has a default
    /// flag, its first, and the row toggle writes it.
    func testAPaletteStoredAsAllSwitchedOffStillTogglesItsFirstFlag() async throws {
        let imap = FakeImapClient()
        let model = try makeList(
            imap: imap, palette: try storedAsSwitchedOff(), envelopes: [TestFixtures.makeEnvelope(uid: 1)]
        )

        XCTAssertEqual(model.defaultFlag.flag, .keyword("cabal-flag-03"))
        XCTAssertTrue(model.defaultFlagIsMissing(from: [ref(1)]))
        await model.toggleDefaultFlag(model.envelopes[0])

        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.keyword("cabal-flag-03")]])
        XCTAssertEqual(calls.map(\.operation), [.add])
        XCTAssertFalse(model.defaultFlagIsMissing(from: [ref(1)]))
    }

    // MARK: - Selections

    /// The selection menu, the bulk bar and Cmd+Shift+8: any row without
    /// the default flag means "set it on all".
    func testASelectionGetsTheDefaultFlagWhenAnyRowLacksIt() async throws {
        let imap = FakeImapClient()
        let model = try makeList(imap: imap, palette: [todo, system], envelopes: [
            TestFixtures.makeEnvelope(uid: 1, flags: [.keyword("cabal-flag-03")]),
            TestFixtures.makeEnvelope(uid: 2, flags: [.flagged]),
        ])
        let refs: Set<MessageRef> = [ref(1), ref(2)]

        XCTAssertTrue(model.defaultFlagIsMissing(from: refs), "the server's flag on row 2 is not the default flag")
        await model.setDefaultFlag(true, refs: refs)

        XCTAssertFalse(model.defaultFlagIsMissing(from: refs))
        XCTAssertTrue(model.envelopes.allSatisfy { $0.flags.contains(.keyword("cabal-flag-03")) })
        XCTAssertTrue(model.envelopes[1].flags.contains(.flagged), "the other flag is left alone")
        let calls = await imap.flagCalls
        XCTAssertEqual(Set(calls.flatMap(\.flags)), [.keyword("cabal-flag-03")])
    }

    // MARK: - Reader

    func testTheReaderButtonWritesTheDefaultFlag() async throws {
        let imap = FakeImapClient()
        let reader = try makeReader(imap: imap, palette: [todo, system], flags: [.flagged])

        XCTAssertFalse(reader.isDefaultFlagSet, "flagged, but not with the default flag")
        XCTAssertEqual(reader.defaultFlag.title(isSet: reader.isDefaultFlagSet), "Todo")

        await reader.toggleDefaultFlag()

        XCTAssertTrue(reader.isDefaultFlagSet)
        XCTAssertEqual(reader.defaultFlag.title(isSet: reader.isDefaultFlagSet), "Remove Todo")
        XCTAssertEqual(reader.keywordSlots, ["cabal-flag-03"])
        XCTAssertTrue(reader.isFlagged, "the server's flag is left alone")
        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.keyword("cabal-flag-03")]])
    }

    func testTheReaderButtonKeepsTogglingTheServersFlagForAnUntouchedPalette() async throws {
        let imap = FakeImapClient()
        let reader = try makeReader(imap: imap, palette: [])

        await reader.toggleDefaultFlag()

        XCTAssertTrue(reader.isFlagged)
        XCTAssertTrue(reader.isDefaultFlagSet)
        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.flagged]])
    }

    /// The flag menu's rows toggle by slot, the built-in flag's among them.
    func testTheReaderMenuTogglesAnyPaletteFlag() async throws {
        let imap = FakeImapClient()
        let reader = try makeReader(imap: imap, palette: [todo, system])

        await reader.toggle(.flagged)
        await reader.toggle(.keyword("cabal-flag-03"))
        await reader.toggle(.seen)

        XCTAssertEqual(reader.shownFlags, [.flagged, .keyword("cabal-flag-03")])
        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.flagged], [.keyword("cabal-flag-03")]], "\\Seen is not a palette flag")
    }

    /// The reader's half of the same rule: a built-in flag stored as
    /// switched off, alone in the palette, is what the button writes.
    func testTheReaderButtonWritesABuiltInFlagStoredAsSwitchedOff() async throws {
        let imap = FakeImapClient()
        let reader = try makeReader(imap: imap, palette: Array(try storedAsSwitchedOff().dropFirst()))

        XCTAssertEqual(reader.defaultFlag.flag, .flagged)
        await reader.toggleDefaultFlag()

        XCTAssertTrue(reader.isFlagged)
        let calls = await imap.flagCalls
        XCTAssertEqual(calls.map(\.flags), [[.flagged]])
    }
}
