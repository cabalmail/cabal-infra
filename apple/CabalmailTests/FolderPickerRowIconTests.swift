import XCTest
import SwiftUI
import CabalmailKit
@testable import Cabalmail

// Pins the folder-picker icon vocabulary that MoveToFolderSheet and
// NotificationFolderPickerView share through FolderPickerRow.
//
// Deliberately NOT the sidebar's mapping: FolderListView+Helpers.iconName
// uses "doc" for Drafts and "xmark.bin" for Junk. The two sets have always
// differed; these assertions exist so a future edit to one doesn't silently
// drift the other.
final class FolderPickerRowIconTests: XCTestCase {

    func testSystemFoldersKeepTheirIcons() {
        let expected = [
            "INBOX": "tray",
            "Sent": "paperplane",
            "Drafts": "pencil.line",
            "Trash": "trash",
            "Junk": "exclamationmark.shield",
            "Archive": "archivebox"
        ]
        for (path, icon) in expected {
            XCTAssertEqual(
                FolderPickerRow<EmptyView>.icon(for: Folder(path: path)),
                icon,
                "icon for \(path)"
            )
        }
        XCTAssertEqual(
            Set(expected.keys), FolderTree.systemPaths,
            "the mapping and FolderTree.systemPaths have drifted apart"
        )
    }

    func testUserFoldersFallBackToTheGenericIcon() {
        for path in ["Projects", "Projects/2026", "Parent/INBOX", "Sent/Old", ""] {
            XCTAssertEqual(
                FolderPickerRow<EmptyView>.icon(for: Folder(path: path)),
                "folder",
                "icon for \(path)"
            )
        }
    }
}
