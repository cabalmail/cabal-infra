import Foundation
import CabalmailKit

/// One row of the reader's custom-flag menu: everything the row draws,
/// plus whether it is checked.
///
/// A value type rather than a bare slot id because the menu's SwiftUI
/// identity is derived from what it draws (see `FlagMenuPolicy.identity`),
/// and a row's label can change without its slot changing.
struct FlagMenuRow: Equatable, Hashable, Identifiable {
    let slot: String
    let label: String
    let isOn: Bool

    var id: String { slot }
}

/// What the reader's flag menu offers, and the identity SwiftUI needs to
/// redraw it.
///
/// A pure rule rather than inline `if`s in the view so it can be tested
/// directly — the same reason `CompactColumnPolicy` is its own type.
///
/// **Why an identity at all.** On macOS a toolbar `Menu` materializes its
/// AppKit menu once per SwiftUI view identity and then keeps it: measured
/// on 26.6.2 (#1329), re-opening the menu still queries the `Toggle`
/// bindings, gets the new answer, and draws neither the new checkmark nor
/// even a changed row *title*. So the menu's identity has to carry the
/// state it displays, or a tag applied from the menu itself reads as
/// unapplied — and picking the row again removes it. Re-identifying the
/// individual rows is not enough (measured: it changes nothing); the
/// `Menu` itself is what has to be replaced.
enum FlagMenuPolicy {
    /// The rows the menu offers: every enabled palette entry, plus any
    /// slot the message is already tagged with whose entry is disabled or
    /// deleted — those still need an untag affordance (the palette
    /// editor's delete confirmation promises tags stay removable). A
    /// deleted slot's surviving tag is labelled by slot id, having no
    /// palette entry to name it.
    static func rows(
        palette: [FlagPaletteEntry],
        taggedSlots: Set<String>
    ) -> [FlagMenuRow] {
        let offered = palette.filter(\.enabled)
        let offeredSlots = Set(offered.map(\.slot))
        let stray = FlagPalette.slots.filter {
            taggedSlots.contains($0) && !offeredSlots.contains($0)
        }
        return offered.map {
            FlagMenuRow(slot: $0.slot, label: $0.label, isOn: taggedSlots.contains($0.slot))
        } + stray.map { slot in
            FlagMenuRow(
                slot: slot,
                label: palette.first { $0.slot == slot }?.label ?? slot,
                isOn: true
            )
        }
    }

    /// Identity for the `Menu`, covering everything a row draws so any
    /// visible change replaces the menu. Order is part of it: the palette's
    /// array order is the display order.
    ///
    /// The rule has one implementation, shared with the reader's other
    /// option menus (#1337) — writing it a second time is what let those
    /// menus keep the defect after this one was fixed.
    static func identity(_ rows: [FlagMenuRow]) -> String {
        ReaderOptionMenuPolicy.identity(rows.map {
            ReaderMenuRow(option: $0.slot, key: $0.slot, label: $0.label, isOn: $0.isOn)
        })
    }
}
