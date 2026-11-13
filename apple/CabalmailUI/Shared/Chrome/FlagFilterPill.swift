import SwiftUI
import CabalmailKit

/// The Flagged pill of a list bar while it is a menu
/// (`FlagFilterMenuPolicy`): the same face as `FilterPill`, and a tap or a
/// click opens the flags to filter by. No chevron; the pill looks as the
/// plain one beside it does.
///
/// The rows that can be checked are `Toggle`s, so the mark is the menu's
/// own (#1367); Clear filter is an action, so it is a `Button`. Not a
/// `Picker`: on macOS a picker in a menu is a submenu unless it is inline
/// (#1508), and these rows are not one choice (Clear filter is none).
struct FlagFilterPill: View {
    let pill: FlagFilterPillModel
    /// Machine-facing name, kept on the pill as the plain pill keeps its.
    let identifier: String
    let choose: (FlagFilterChoice) -> Void

    var body: some View {
        Menu {
            ForEach(pill.rows) { row in
                if row.startsGroup { Divider() }
                if row.option == .clear {
                    Button(row.label) { choose(row.option) }
                        .disabled(!row.isEnabled)
                } else {
                    Toggle(isOn: Binding(get: { row.isOn }, set: { _ in choose(row.option) })) {
                        Text(row.label)
                    }
                }
            }
        } label: {
            FilterPillFace(label: pill.label, isOn: pill.isOn, count: pill.count, reservedCount: pill.reservedCount)
                // The padding and the unlit wash draw nothing; without a
                // shape of its own only the text would take the tap.
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        // No chevron. On macOS the plain style draws none whatever this
        // says; it is said for the platforms whose default is not ours.
        .menuIndicator(.hidden)
        // The face keeps its own line (`FilterPillFace`) and this keeps
        // the menu's: either alone holds the label on one line.
        .fixedSize()
        .accessibilityLabel(FilterPill.spokenLabel(pill.name, count: pill.count))
        .accessibilityHint("Filter by flag")
        .accessibilityAddTraits(pill.isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        // The menu is rebuilt when a row changes; see
        // `FlagFilterMenuPolicy.identity`.
        .id(FlagFilterMenuPolicy.identity(pill.rows))
    }
}
