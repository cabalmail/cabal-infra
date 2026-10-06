import Foundation
import CabalmailKit

/// One option the list's sort menu offers: a sort field, or a sort
/// direction. Both groups live in one menu and exactly one row of each is
/// in effect, so they share a row type and differ only in what picking
/// them changes.
enum SortMenuOption: Hashable {
    case field(SortCriterion.Field)
    case direction(SortCriterion.Direction)
}

/// What the message list's sort menu offers, and the identity SwiftUI
/// needs to redraw it.
///
/// A pure rule rather than inline `if`s in the view, for the reason
/// `FlagMenuPolicy` and `ReaderOptionMenuPolicy` are: the rows can then be
/// tested directly.
///
/// **Why the rows carry `isOn` rather than the view drawing a glyph.** The
/// menu used to mark the active field with its own
/// `Label(…, systemImage: "checkmark")` and the direction with an
/// `arrow.up`/`arrow.down`. Both are pictures inside a row's label, so
/// `AXMenuItemMarkChar` was `missing value` on every row and a VoiceOver
/// user could hear neither which field was active nor which direction was
/// in effect (#1367). A `Toggle` sets the native mark, which is what the
/// reader's option menus already do.
///
/// **Why an identity.** That `Toggle` brings macOS's materialize-once
/// behaviour with it: a `Menu`'s AppKit menu is built once per SwiftUI
/// view identity and then kept, checkmarks included (#1329, #1337). The
/// rule has one implementation, shared with the reader's option menus —
/// writing it a second time is what let those menus keep the defect after
/// the flag menu was fixed.
enum SortMenuPolicy {
    /// The rows the menu offers: one per sort field, then a divider, then
    /// one per direction. Exactly one row in each group is checked.
    static func rows(criterion: SortCriterion) -> [ReaderMenuRow<SortMenuOption>] {
        SortCriterion.Field.allCases.map { field in
            ReaderMenuRow(
                option: .field(field),
                key: "field.\(field.rawValue)",
                label: label(for: field),
                isOn: field == criterion.field
            )
        } + directionOrder.enumerated().map { position, direction in
            ReaderMenuRow(
                option: .direction(direction),
                key: "direction.\(direction.rawValue)",
                label: label(for: direction),
                isOn: direction == criterion.direction,
                startsGroup: position == 0
            )
        }
    }

    /// Reading order for the direction group. Spelled out rather than
    /// taken from `allCases`, whose source order puts the default
    /// (`descending`) first — in a menu the two read as a pair and
    /// ascending-then-descending is the conventional order.
    static let directionOrder: [SortCriterion.Direction] = [.ascending, .descending]

    /// The criterion picking `option` produces, applied to the criterion in
    /// effect: a field row keeps the current direction and a direction row
    /// keeps the current field.
    static func criterion(
        picking option: SortMenuOption,
        from current: SortCriterion
    ) -> SortCriterion {
        switch option {
        case .field(let field):
            return SortCriterion(field: field, direction: current.direction)
        case .direction(let direction):
            return SortCriterion(field: current.field, direction: direction)
        }
    }

    /// Identity for the `Menu`, covering everything a row draws so any
    /// visible change replaces the menu.
    static func identity(_ rows: [ReaderMenuRow<SortMenuOption>]) -> String {
        ReaderOptionMenuPolicy.identity(rows)
    }

    static func label(for field: SortCriterion.Field) -> String {
        switch field {
        case .dateReceived: return "Date Received"
        case .dateSent:     return "Date Sent"
        case .from:         return "From"
        case .subject:      return "Subject"
        }
    }

    static func label(for direction: SortCriterion.Direction) -> String {
        switch direction {
        case .ascending:  return "Ascending"
        case .descending: return "Descending"
        }
    }
}
