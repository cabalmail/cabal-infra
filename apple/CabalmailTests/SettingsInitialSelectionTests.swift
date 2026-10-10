import XCTest
@testable import CabalmailUI

/// Which category Settings opens on (`SettingsView.initialSelection(on:)`,
/// over `HostPlatform.settingsOpensBothColumns`).
@MainActor
final class SettingsInitialSelectionTests: XCTestCase {
    /// The Mac's Settings window and the visionOS Settings tab draw the
    /// category list and a category side by side, so they open on Account
    /// rather than on an empty pane.
    func testTheTwoColumnHostsOpenOnAccount() {
        XCTAssertEqual(SettingsView.initialSelection(on: .macOS), .account)
        XCTAssertEqual(SettingsView.initialSelection(on: .visionOS), .account)
    }

    /// iOS opens on the list, on the phone's tab and in the iPad's sheet: a
    /// category chosen in advance would push straight past it.
    func testIOSOpensOnTheList() {
        XCTAssertNil(SettingsView.initialSelection(on: .iOS))
    }

    /// The watch has no Settings view; the capability still answers, as the
    /// phone does, rather than trapping.
    func testOnlyTheMacAndVisionOpenBothColumns() {
        XCTAssertTrue(HostPlatform.macOS.settingsOpensBothColumns)
        XCTAssertTrue(HostPlatform.visionOS.settingsOpensBothColumns)
        XCTAssertFalse(HostPlatform.iOS.settingsOpensBothColumns)
        XCTAssertFalse(HostPlatform.watchOS.settingsOpensBothColumns)
    }
}
