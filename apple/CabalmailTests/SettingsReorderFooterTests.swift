import XCTest
@testable import CabalmailUI

/// What the Rules and Flags footers say about reordering, per host. A
/// grouped form on macOS ignores `onMove`, so a Mac footer must never
/// promise a drag: Flags said "Drag to reorder" there and its rows never
/// moved (#2019). The Mac footers name the row menus; the edit-mode hosts
/// say to tap Edit and drag.
@MainActor
final class SettingsReorderFooterTests: XCTestCase {
    private func footers(on host: HostPlatform) -> [String] {
        [
            RulesView.listFooter(on: host),
            FlagPaletteSettingsView.footerText(paletteIsEmpty: false, on: host),
        ]
    }

    func testMacFootersNeverPromiseADrag() {
        for footer in footers(on: .macOS) {
            XCTAssertFalse(footer.localizedCaseInsensitiveContains("drag"), footer)
            XCTAssertTrue(footer.localizedCaseInsensitiveContains("right-click"), footer)
        }
        XCTAssertTrue(RulesView.listFooter(on: .macOS).contains("⋯ menu"))
    }

    func testEditModeHostsSayToTapEditAndDrag() {
        for host in [HostPlatform.iOS, .visionOS] {
            for footer in footers(on: host) {
                XCTAssertTrue(footer.localizedCaseInsensitiveContains("tap Edit to drag"), footer)
            }
        }
    }

    func testFootersStillSayWhatTheOrderMeans() {
        for host in [HostPlatform.iOS, .visionOS, .macOS] {
            XCTAssertTrue(RulesView.listFooter(on: host).hasPrefix("Rules run top to bottom"))
            XCTAssertTrue(
                FlagPaletteSettingsView.footerText(paletteIsEmpty: false, on: host)
                    .contains("the order here is the order pickers use")
            )
        }
    }

    func testAnEmptyPaletteFooterOffersNoReorder() {
        for host in [HostPlatform.iOS, .visionOS, .macOS] {
            let footer = FlagPaletteSettingsView.footerText(paletteIsEmpty: true, on: host)
            XCTAssertFalse(footer.localizedCaseInsensitiveContains("drag"), footer)
            XCTAssertFalse(footer.localizedCaseInsensitiveContains("right-click"), footer)
        }
    }
}
