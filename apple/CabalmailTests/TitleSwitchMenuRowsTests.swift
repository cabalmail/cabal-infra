import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The rows both list-column title menus draw (`TitleSwitchMenuRows`): the
/// folder menu above the message list and the scope menu above the feed item
/// list. Which row is checked is each menu policy's business and has its own
/// tests; this covers what a row's toggle does, through the binding the row
/// draws.
@MainActor
final class TitleSwitchMenuRowsTests: XCTestCase {

    /// A row's toggle reads its check from the row.
    func testTheToggleShowsTheRowsCheck() {
        let checked = ReaderMenuRow(option: "INBOX", key: "INBOX", label: "INBOX", isOn: true)
        let unchecked = ReaderMenuRow(option: "Sent", key: "Sent", label: "Sent", isOn: false)
        XCTAssertTrue(TitleSwitchMenuRows<String>.isOn(checked, pick: { _ in }).wrappedValue)
        XCTAssertFalse(TitleSwitchMenuRows<String>.isOn(unchecked, pick: { _ in }).wrappedValue)
    }

    /// Picking an unchecked row switches to it, once.
    func testPickingAnUncheckedRowSwitchesToIt() {
        var picked: [String] = []
        let row = ReaderMenuRow(option: "Sent", key: "Sent", label: "Sent", isOn: false)
        TitleSwitchMenuRows<String>.isOn(row, pick: { picked.append($0) }).wrappedValue = true
        XCTAssertEqual(picked, ["Sent"])
    }

    /// Re-picking the choice the list is already on switches nothing: the
    /// parent would only re-key the same view. A menu toggles the checked
    /// row off when it is picked again, so that is the write to ignore.
    func testPickingTheCheckedRowIsANoOp() {
        var picked: [String] = []
        let row = ReaderMenuRow(option: "INBOX", key: "INBOX", label: "INBOX", isOn: true)
        let binding = TitleSwitchMenuRows<String>.isOn(row, pick: { picked.append($0) })
        binding.wrappedValue = false
        binding.wrappedValue = true
        XCTAssertEqual(picked, [])
    }

    /// Over a real folder menu, every row switches except the folder the list
    /// is on, wherever that folder sits.
    func testOnlyTheCurrentFolderIsInertInTheFolderMenu() {
        let folders = [
            Folder(path: "INBOX", attributes: [], isSubscribed: true),
            Folder(path: "Sent", attributes: [], isSubscribed: true),
            Folder(path: "Archive", attributes: [], isSubscribed: false),
        ]
        let current = Folder(path: "Archive", attributes: [], isSubscribed: false)
        let groups = FolderSwitchMenuPolicy.groups(folders: folders, current: current)
        var picked: [String] = []
        for row in groups.subscribed + groups.other {
            TitleSwitchMenuRows<Folder>.isOn(row, pick: { picked.append($0.path) }).wrappedValue.toggle()
        }
        XCTAssertEqual(picked.sorted(), ["INBOX", "Sent"])
    }
}
