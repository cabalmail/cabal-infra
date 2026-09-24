import SwiftUI
import CabalmailKit

/// One pill of a sidebar filter row.
struct SidebarFilterPill: Identifiable {
    let id: String
    let label: String
    let isOn: Bool
    let action: () -> Void
}

/// The filter row above a sidebar tree: pills on the leading edge, the
/// Expand all / Collapse all affordances on the trailing edge. Drawn the way
/// the message list's `filterPill` and the feed item list's `filterBar`
/// draw theirs — same font, padding, and accent wash — so the three rows
/// read as one control family. The pills' semantics (radio vs. toggles) are
/// the caller's; this only draws what it is told is on.
struct SidebarFilterPillRow: View {
    let pills: [SidebarFilterPill]
    /// Machine-facing prefix for the pills (`folder.filter` / `feed.filter`);
    /// each pill is `<prefix>.pill.<id>`, the tree buttons
    /// `<prefix>.expandAll` / `<prefix>.collapseAll`.
    let identifierPrefix: String
    /// Nil hides the tree affordances (the flat compact feed list has none
    /// to offer beside its folders; the caller decides).
    let expansion: Expansion?

    struct Expansion {
        /// False when nothing in the tree has children: the buttons stay
        /// visible (stable footprint) but disabled.
        let hasCollapsible: Bool
        let expandAll: () -> Void
        let collapseAll: () -> Void
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(pills) { pill in
                Button(action: pill.action) {
                    Text(pill.label)
                        .font(.subheadline.weight(pill.isOn ? .semibold : .regular))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(pill.isOn ? ColorTokens.accentForestWash : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pill.isOn ? .isSelected : [])
                .accessibilityIdentifier("\(identifierPrefix).pill.\(pill.id)")
            }
            Spacer(minLength: 4)
            if let expansion {
                Button(action: expansion.expandAll) {
                    Image(systemName: "rectangle.expand.vertical")
                        .accessibilityLabel("Expand all folders")
                }
                .buttonStyle(.borderless)
                .disabled(!expansion.hasCollapsible)
                .accessibilityIdentifier("\(identifierPrefix).expandAll")
                Button(action: expansion.collapseAll) {
                    Image(systemName: "rectangle.compress.vertical")
                        .accessibilityLabel("Collapse all folders")
                }
                .buttonStyle(.borderless)
                .disabled(!expansion.hasCollapsible)
                .accessibilityIdentifier("\(identifierPrefix).collapseAll")
            }
        }
    }
}
