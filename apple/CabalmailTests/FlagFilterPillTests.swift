import XCTest
import SwiftUI
import AppKit
import CabalmailKit
@testable import CabalmailUI

/// `FlagFilterPill`, the Flagged pill as a menu, takes the room of the
/// plain `FilterPill` beside it. The bar's pills stack when the row stops
/// fitting (`FilterPillStrip`), so a menu that measured wider, by a chevron
/// or a bezel, would stack them sooner and move the list.
@MainActor
final class FlagFilterPillTests: XCTestCase {
    private func menuPill(_ label: String, isOn: Bool, count: Int?, reserved: Int? = nil) -> FlagFilterPill {
        FlagFilterPill(
            pill: FlagFilterPillModel(
                label: label, name: label, isOn: isOn, count: count, reservedCount: reserved,
                rows: FlagFilterMenuPolicy.rows(
                    palette: [FlagPaletteEntry(slot: "cabal-flag-03", label: "Later", color: "blue")], current: nil
                )
            ),
            identifier: "probe"
        ) { _ in }
    }

    private func size<V: View>(of view: V, width: CGFloat = 1_000) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 10_000))
    }

    func testTheMenuPillIsTheSizeOfThePlainPill() {
        for (label, isOn, count) in [("Flagged", false, 128), ("Flagged", true, 128), ("Later", true, 7)] {
            let plain = size(of: FilterPill(label: label, isOn: isOn, count: count, identifier: "probe") {})
            let menu = size(of: menuPill(label, isOn: isOn, count: count))

            XCTAssertEqual(menu.width, plain.width, accuracy: 0.5, "\(label) \(isOn): a chevron or a bezel adds width")
            XCTAssertEqual(menu.height, plain.height, accuracy: 0.5, "\(label) \(isOn)")
        }
        let bare = size(of: FilterPill(label: "Later", isOn: true, identifier: "probe") {})
        XCTAssertEqual(size(of: menuPill("Later", isOn: true, count: nil)).width, bare.width, accuracy: 0.5)
    }

    func testTheMenuPillKeepsItsLabelOnOneLineWhenSqueezed() {
        let pill = menuPill("Waiting on reply", isOn: true, count: 128)

        XCTAssertEqual(size(of: pill, width: 8).height, size(of: pill).height, accuracy: 0.5)
    }

    /// While a pick's number is on its way the face keeps the room for one,
    /// so the pill is as wide before the answer as after it.
    func testAPendingNumberTakesTheRoomOfTheNumber() {
        let counted = size(of: FilterPillFace(label: "Later", isOn: true, count: 128))
        let waiting = size(of: FilterPillFace(label: "Later", isOn: true, count: nil, reservedCount: 128))
        let bare = size(of: FilterPillFace(label: "Later", isOn: true, count: nil))

        XCTAssertEqual(waiting.width, counted.width, accuracy: 0.5)
        XCTAssertGreaterThan(counted.width, bare.width + 5, "the number does take room")
    }
}
