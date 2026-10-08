import SwiftUI
import CabalmailKit

/// The chevron of a sidebar tree row that has rows under it.
struct SidebarTreeDisclosure {
    let isCollapsed: Bool
    /// The name VoiceOver reads after "Expand" / "Collapse".
    let name: String
    /// Machine-facing name for the chevron, when the tree has one.
    var identifier: String?
    let toggle: () -> Void
}

/// One row of a sidebar tree: indentation, the disclosure chevron, an icon,
/// the title, and a trailing slot (the count badge, a feed's health mark).
/// The mail folder rows and the feed rows both draw it, so the two trees
/// indent, tint and disclose alike.
struct SidebarTreeRowLabel<Trailing: View>: View {
    let title: String
    let systemImage: String
    /// Indentation steps, one per ancestor the tree shows.
    let depth: Int
    /// Nil for a row with nothing under it; its chevron slot stays reserved.
    let disclosure: SidebarTreeDisclosure?
    let hasUnread: Bool
    let isSelected: Bool
    /// Nil lets a long title wrap (mail folder names); feed titles keep to
    /// one line.
    var titleLineLimit: Int?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            // Always reserve the chevron slot so the icon column stays
            // aligned across leaf and parent rows at the same depth. Without
            // the placeholder, parent rows shift right by the chevron's width
            // and read as one indent level deeper than their peers.
            Group {
                if let disclosure {
                    chevron(disclosure)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 14)
            Image(systemName: systemImage)
                // Accent while unselected, and the row's own foreground once
                // it is: the selection fill is the platform's to choose and no
                // pinned color survives all of the ones it draws (#1318).
                .foregroundStyle(Self.iconStyle(isSelected: isSelected))
            Text(title)
                .lineLimit(titleLineLimit)
                .foregroundStyle(Self.titleStyle(hasUnread: hasUnread, isSelected: isSelected))
            Spacer()
            trailing()
        }
        #if os(visionOS)
        // visionOS spatial UIs want an explicit hover affordance: eye
        // tracking highlights the row before the user commits with a pinch,
        // and the default list row doesn't provide that feedback out of the
        // box. `.hoverEffect(.highlight)` matches Apple Mail on visionOS.
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        #endif
    }

    @ViewBuilder
    private func chevron(_ disclosure: SidebarTreeDisclosure) -> some View {
        let button = Button(action: disclosure.toggle) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(disclosure.isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
        }
        // Borderless lets the chevron handle taps without also triggering
        // row selection in the surrounding List.
        .buttonStyle(.borderless)
        .accessibilityLabel(disclosure.isCollapsed ? "Expand \(disclosure.name)" : "Collapse \(disclosure.name)")
        if let identifier = disclosure.identifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }

    /// Foreground for the row's icon. `FolderIconTint` owns the rule and
    /// records what each candidate is worth in contrast (#1318); this only
    /// spells the cases as styles. The accent is the asset-catalog color,
    /// pinned explicitly rather than ridden through `.tint`: macOS repaints
    /// environment tints with the user's system accent (System Settings >
    /// Appearance) whenever that isn't "multicolor", which left the wide
    /// layouts' icons off-brand.
    static func iconStyle(isSelected: Bool) -> AnyShapeStyle {
        switch FolderIconTint.tint(isSelected: isSelected) {
        case .inherited: return AnyShapeStyle(.primary)
        case .accent:    return AnyShapeStyle(ColorTokens.accentForestFg)
        }
    }

    /// Foreground for the title: accent while the row has unread items,
    /// dimmed once it's caught up, and left alone on the selected row.
    /// `FolderNameTint` owns the rule and records what each case is worth in
    /// contrast (#1297); this only spells the cases as styles, with the
    /// accent pinned for the reason `iconStyle` gives.
    static func titleStyle(hasUnread: Bool, isSelected: Bool) -> AnyShapeStyle {
        switch FolderNameTint.tint(hasUnread: hasUnread, isSelected: isSelected) {
        case .inherited: return AnyShapeStyle(.primary)
        case .unread:    return AnyShapeStyle(ColorTokens.accentForestFg)
        case .caughtUp:  return AnyShapeStyle(Color.primary.opacity(FolderNameTint.dimmedOpacity))
        }
    }
}
