import Foundation
import CabalmailKit

/// One row of a reader option menu: everything the row draws, plus the
/// state it displays.
///
/// A value type rather than the bare option because the menu's SwiftUI
/// identity is derived from what it draws (see
/// `ReaderOptionMenuPolicy.identity`), and every field here was measured
/// to freeze with the menu: the checkmark, the row title, and — on the
/// mark-read menu — the *disabled* state (#1337).
struct ReaderMenuRow<Option: Hashable>: Identifiable {
    /// The option the row stands for, handed back to the row's action.
    let option: Option
    /// Stable identity of that option, independent of what it draws.
    let key: String
    let label: String
    let isOn: Bool
    let isEnabled: Bool
    /// A divider precedes this row — the dispose menu groups by action.
    let startsGroup: Bool

    var id: String { key }

    init(
        option: Option,
        key: String,
        label: String,
        isOn: Bool,
        isEnabled: Bool = true,
        startsGroup: Bool = false
    ) {
        self.option = option
        self.key = key
        self.label = label
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.startsGroup = startsGroup
    }
}

/// The reader toolbar's mark-read and dispose option menus: what they
/// offer, and the identity SwiftUI needs to redraw them.
///
/// Same rule and same reason as `FlagMenuPolicy`, which is where it was
/// first measured. macOS materializes a toolbar `Menu`'s AppKit menu once
/// per SwiftUI view identity and then keeps it: re-opening still queries
/// the `Toggle` bindings and gets the new answer, and draws the old menu
/// anyway. #1337 measured that on these two surfaces — a mark-read option
/// chosen from the menu itself, or an option changed in Settings with the
/// reader still open, both left the checkmark on the previous row, and the
/// mark-read rows kept drawing *enabled* after the message became seen.
/// So a menu's identity has to carry everything its rows draw.
///
/// The list's sort menu is deliberately not here: it draws its own
/// `Label(…, systemImage: "checkmark")` rather than a `Toggle`, and #1337
/// measured it updating correctly.
enum ReaderOptionMenuPolicy {
    /// The mark-read menu: one row per `MarkReadAdvance`, checked against
    /// the current default. The options only apply to an unread message —
    /// a mark-unread never navigates — so they are disabled once the open
    /// message reads as seen.
    static func seenRows(
        advance selected: MarkReadAdvance,
        isSeen: Bool
    ) -> [ReaderMenuRow<MarkReadAdvance>] {
        MarkReadAdvance.allCases.map { advance in
            ReaderMenuRow(
                option: advance,
                key: advance.rawValue,
                label: "Mark Read and \(seenAdvanceDescription(for: advance))",
                isOn: advance == selected,
                isEnabled: !isSeen
            )
        }
    }

    /// The dispose menu: every action × advance combination, grouped by
    /// action, checked against the current pair.
    ///
    /// `verbs` carries the reconciled verb per action rather than the raw
    /// action, so the rows read true in the special folders (Delete Forever
    /// inside Trash, Restore inside Archive) — and so the verb the identity
    /// is built from is the one the row draws.
    static func disposeRows(
        verbs: [(action: DisposeAction, verb: String)],
        selectedAction: DisposeAction,
        selectedAdvance: DisposeAdvance
    ) -> [ReaderMenuRow<DisposeOption>] {
        verbs.enumerated().flatMap { index, pair in
            DisposeAdvance.allCases.enumerated().map { position, advance in
                let option = DisposeOption(action: pair.action, advance: advance)
                return ReaderMenuRow(
                    option: option,
                    key: option.id,
                    label: "\(pair.verb) and \(disposeAdvanceDescription(for: advance))",
                    isOn: pair.action == selectedAction && advance == selectedAdvance,
                    startsGroup: index > 0 && position == 0
                )
            }
        }
    }

    /// Identity for the `Menu`, covering everything a row draws so any
    /// visible change replaces the menu — and nothing else, so an
    /// unchanged menu is not rebuilt on every body pass.
    static func identity<Option>(_ rows: [ReaderMenuRow<Option>]) -> String {
        rows.map {
            [
                $0.key,
                $0.label,
                $0.isOn ? "1" : "0",
                $0.isEnabled ? "1" : "0",
                $0.startsGroup ? "1" : "0",
            ].joined(separator: "\u{1E}")
        }
        .joined(separator: "\u{1F}")
    }

    static func seenAdvanceDescription(for advance: MarkReadAdvance) -> String {
        switch advance {
        case .stay:           return "Stay Here"
        case .nextUnread:     return "Move to Next Unread"
        case .previousUnread: return "Move to Previous Unread"
        case .firstUnread:    return "Move to First Unread"
        }
    }

    static func disposeAdvanceDescription(for advance: DisposeAdvance) -> String {
        switch advance {
        case .next:           return "Move to Next Message"
        case .nextUnread:     return "Move to Next Unread"
        case .previousUnread: return "Move to Previous Unread"
        case .firstUnread:    return "Move to First Unread"
        }
    }
}

/// One dispose-menu option: the action/advance pair the row applies.
struct DisposeOption: Hashable, Identifiable {
    let action: DisposeAction
    let advance: DisposeAdvance

    var id: String { "\(action.rawValue)\u{1E}\(advance.rawValue)" }
}
