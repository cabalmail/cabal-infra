#if os(macOS)
import AppKit
import XCTest
@testable import CabalmailUI

// SwiftUI names the main window's split for AppKit's autosave, and on macOS 27
// AppKit restored the message list from it short by the sidebar's width: a
// 481pt list beside a 340pt sidebar came back at 141pt and was pushed to its
// 300pt floor. The columns remember their own widths; AppKit's copy has to be
// gone before a window is built and must not be written again.
@MainActor
final class SplitViewAutosaveTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SplitViewAutosaveTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The frames AppKit saved for the list/reader split in the probe that
    /// reproduced the restore: sidebar 340, list 481, reader 678.
    private let savedFrames = [
        "0.000000, 0.000000, 340.000000, 850.000000, NO, NO",
        "340.000000, 0.000000, 481.000000, 850.000000, NO, NO",
        "822.000000, 0.000000, 678.000000, 850.000000, NO, NO"
    ]

    private func framesKey(_ autosaveName: String) -> String {
        SplitViewAutosave.savedFramesKeyPrefix + autosaveName
    }

    func testLaunchClearsEveryMainWindowsSavedSplit() {
        let first = framesKey("main-AppWindow-1, SidebarNavigationSplitView")
        let second = framesKey("main-AppWindow-2, SidebarNavigationSplitView")
        defaults.set(savedFrames, forKey: first)
        defaults.set(savedFrames, forKey: second)

        SplitViewAutosave.clearSavedFrames(windowGroupID: "main", in: defaults)

        XCTAssertNil(defaults.object(forKey: first))
        XCTAssertNil(defaults.object(forKey: second))
    }

    // Only the main window's splits: the Settings window's split, the main
    // window's own frame, and the widths the columns remember stay put.
    func testLaunchLeavesEverythingElseAlone() {
        let settings = framesKey("com_apple_SwiftUI_Settings_window, SidebarNavigationSplitView")
        let unrelated = [
            settings: savedFrames as Any,
            "NSWindow Frame main-AppWindow-1": "200 100 1500 850 0 0 1920 1050 ",
            SidebarColumnWidth.storageKey: 340.0,
            ListColumnWidth.storageKey: 481.0,
            AddressInspectorWidth.storageKey: 381.0
        ]
        for (key, value) in unrelated { defaults.set(value, forKey: key) }

        SplitViewAutosave.clearSavedFrames(windowGroupID: "main", in: defaults)

        for key in unrelated.keys {
            XCTAssertNotNil(defaults.object(forKey: key), key)
        }
    }

    // The window's own split stops saving, and drops what it saved so far, so a
    // split built later in the session has nothing to restore.
    func testDisablingStopsTheSplitSavingAndDropsItsFrames() {
        let name = "main-AppWindow-1, SidebarNavigationSplitView"
        let split = NSSplitView()
        split.autosaveName = name
        defaults.set(savedFrames, forKey: framesKey(name))

        SplitViewAutosave.disable(split, in: defaults)

        XCTAssertNil(split.autosaveName)
        XCTAssertNil(defaults.object(forKey: framesKey(name)))
    }

    // The navigation split sits inside the one `.inspector` adds around it; a
    // column's content has to find its own, the nearer one.
    func testAColumnFindsItsOwnSplitNotTheInspectorsAroundIt() {
        let inspectorSplit = NSSplitView()
        let navigationSplit = NSSplitView()
        let column = NSView()
        let content = NSView()
        inspectorSplit.addSubview(navigationSplit)
        navigationSplit.addSubview(column)
        column.addSubview(content)

        XCTAssertIdentical(SplitViewAutosave.enclosingSplitView(of: content), navigationSplit)
        XCTAssertNil(SplitViewAutosave.enclosingSplitView(of: NSView()))
    }
}
#endif
