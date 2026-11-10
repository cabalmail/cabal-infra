import AppKit
import SwiftUI
import XCTest
import CabalmailKit
@testable import CabalmailUI

// ⌘⇧8 is the flag chord of both the Message and the Feeds menu, and their
// two items are retitled whenever the palette changes (each names the flag
// it sets). SwiftUI does not give a menu item it is updating a key
// equivalent another item already holds, so while both menus declared the
// chord the Message item lost it on its first retitle and ⌘⇧8 did nothing
// for anyone whose default flag has a name. One item declares it at a time.
@MainActor
final class FlagChordTests: XCTestCase {
    private static let sections: [ResumeSession.Section] = [.mail, .feeds]

    func testOnlyTheSectionInFrontDeclaresTheChord() {
        for front in Self.sections {
            let holders = Self.sections.filter {
                SharedChordPolicy.flagChord(for: $0, activeSection: front) != nil
            }
            XCTAssertEqual(holders, [front], "\(front) in front")
        }
    }

    func testTheChordIsShiftCommandEight() throws {
        for section in Self.sections {
            let chord = try XCTUnwrap(SharedChordPolicy.flagChord(for: section, activeSection: section))
            XCTAssertEqual(chord.key, KeyEquivalent("8"))
            XCTAssertEqual(chord.modifiers, [.command, .shift])
        }
    }

    /// The item that declares the chord is the one the live rule lets fire:
    /// a section that can act on its selection always has its key.
    func testALiveItemAlwaysHasItsChord() {
        let mail = MessageMenuAvailability(selectedCount: 1, hasOpenMessage: true)
        let feeds = FeedMenuAvailability(selectedCount: 1, hasOpenItem: true, hasScope: true)
        for front in Self.sections {
            if SharedChordPolicy.mailItemsLive(mail, activeSection: front) {
                XCTAssertNotNil(SharedChordPolicy.flagChord(for: .mail, activeSection: front))
            }
            if SharedChordPolicy.feedItemsLive(feeds, activeSection: front) {
                XCTAssertNotNil(SharedChordPolicy.flagChord(for: .feeds, activeSection: front))
            }
        }
    }

    /// The menu bar the app really built, which is where the defect lived:
    /// two items on ⌘⇧8 is the state in which a retitled one loses its key.
    /// Whatever window is in front, exactly one item holds the chord.
    func testTheMenuBarHasOneItemOnTheChord() throws {
        let menuBar = try XCTUnwrap(NSApp.mainMenu, "the test host has no menu bar")
        let titles = Self.items(in: menuBar).map(\.title)
        try XCTSkipUnless(titles.contains("Move to Folder…"), "the Message menu is not built in this host")
        let holders = Self.items(in: menuBar).filter(Self.isOnFlagChord)
        XCTAssertEqual(holders.count, 1, "items on ⌘⇧8: \(holders.map(\.title))")
    }

    private static func isOnFlagChord(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == "8"
            && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items(in:)) ?? []) }
    }
}
