import SwiftUI
import CabalmailKit

/// The feed list itself, which both feed sidebars draw: the mail sidebar's
/// Feeds section on the wide layouts, and the Feeds tab's sidebar on the
/// compact layout and visionOS (`FeedSidebarList`). An error line, then
/// either the empty state or the "All Feeds" row and the folder tree with
/// subscriptions as leaves, each row with its context menu.
///
/// Each sidebar used to build all of this itself, so the two could drift
/// (#1548 was the All Feeds row drifting). What still differs is the list
/// the rows sit in, which `Style` names, and what each host draws around
/// them: the wide section's header and filter pills, the Feeds tab's
/// toolbar, filter field and pills.
struct FeedSidebarContent<Leading: View>: View {
    enum Style: Equatable {
        /// Rows are `Button`s inside the mail sidebar's list, beside its
        /// selection rather than part of it: the iPad's split.
        case rowButtons
        /// Rows are tagged for the host's own `List(selection:)`, whose
        /// selection is a feed list: the Feeds tab's sidebar.
        case listSelection
        /// Rows are tagged for the mail sidebar's list, whose selection is a
        /// `SidebarSelection`, so a feed is selected as a folder is: the Mac.
        case sidebarSelection

        /// The style of the Feeds section inside the mail sidebar's list.
        static func inMailSidebar(on platform: HostPlatform) -> Style {
            platform.sidebarSelectsFeeds ? .sidebarSelection : .rowButtons
        }
    }

    let style: Style
    let model: FeedSidebarViewModel
    @Binding var selection: RssItemScope?
    /// The folder tree's rows, as the host's collapse and filter state shape
    /// them.
    let rows: [FeedSidebarRow]
    let isCollapsed: (String) -> Bool
    let toggleCollapse: (String) -> Void
    let actions: FeedManagementActions
    let management: FeedManagementViewModel?
    /// Drawn above the All Feeds row while there are feeds: the wide
    /// section's filter pills.
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .appFont(.footnote)
                .foregroundStyle(ColorTokens.dangerFg)
        }
        if model.hasLoaded, !model.hasSubscriptions {
            emptyState
        } else {
            leading()
            allFeedsRow
            treeRows
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch style {
        case .rowButtons, .sidebarSelection:
            Button("Subscribe to a feed…") { actions.subscribe() }
                .buttonStyle(.plain)
                .appFont(.footnote)
                .foregroundStyle(ColorTokens.accentForestFg)
                .disabled(management == nil)
                .accessibilityIdentifier("feeds.subscribe.empty")
        case .listSelection:
            ContentUnavailableView {
                Label("No feeds yet", systemImage: "dot.radiowaves.up.forward")
            } description: {
                Text("Subscribe to a feed to start reading here.")
            } actions: {
                Button("Subscribe to a Feed…") { actions.subscribe() }
                    .disabled(management == nil)
            }
            .listRowSeparator(.hidden)
        }
    }

    /// The All Feeds row: every subscription's items in one list, with the
    /// catalog's roll-up as its badge (#1548).
    @ViewBuilder
    private var allFeedsRow: some View {
        let label = FeedSidebarRowLabel(
            row: FeedSidebarRows.allFeedsRow(
                unread: FeedSidebarRows.totalUnread(model.unreadCounts),
                total: FeedSidebarRows.grandTotal(model.totalCounts)
            ),
            isSelected: selection == .all,
            isCollapsed: { _ in true }, toggleCollapse: { _ in }
        )
        switch style {
        case .rowButtons:
            Button {
                selection = .all
            } label: {
                label
            }
            .buttonStyle(.plain)
            .listRowBackground(
                selection == .all ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) : nil
            )
            .contextMenu { menu(for: nil, scope: .all) }
            .accessibilityIdentifier("feed.row.all")
        case .listSelection:
            label
                .tag(RssItemScope.all)
                .contextMenu { menu(for: nil, scope: .all) }
        case .sidebarSelection:
            label
                .sidebarFeedRow(.all, identifier: "feed.row.all")
                .contextMenu { menu(for: nil, scope: .all) }
        }
    }

    @ViewBuilder
    private var treeRows: some View {
        switch style {
        case .rowButtons:
            FeedSidebarRowsView(
                rows: rows, selection: $selection, toggleCollapse: toggleCollapse, isCollapsed: isCollapsed,
                contextMenu: { row in menu(for: row, scope: row.scope) }
            )
        case .listSelection:
            ForEach(rows) { row in
                FeedSidebarRowLabel(row: row, isSelected: selection == row.scope,
                                    isCollapsed: isCollapsed, toggleCollapse: toggleCollapse)
                    .tag(row.scope)
                    .contextMenu { menu(for: row, scope: row.scope) }
            }
        case .sidebarSelection:
            ForEach(rows) { row in
                FeedSidebarRowLabel(row: row, isSelected: selection == row.scope,
                                    isCollapsed: isCollapsed, toggleCollapse: toggleCollapse)
                    .sidebarFeedRow(row.scope, identifier: "feed.row.\(row.id)")
                    .contextMenu { menu(for: row, scope: row.scope) }
            }
        }
    }

    private func menu(for row: FeedSidebarRow?, scope: RssItemScope) -> FeedSidebarContextMenu {
        FeedSidebarContextMenu(scope: scope, row: row, actions: actions, management: management)
    }
}

extension FeedSidebarContent where Leading == EmptyView {
    init(
        style: Style, model: FeedSidebarViewModel, selection: Binding<RssItemScope?>, rows: [FeedSidebarRow],
        isCollapsed: @escaping (String) -> Bool, toggleCollapse: @escaping (String) -> Void,
        actions: FeedManagementActions, management: FeedManagementViewModel?
    ) {
        self.init(
            style: style, model: model, selection: selection, rows: rows, isCollapsed: isCollapsed,
            toggleCollapse: toggleCollapse, actions: actions, management: management, leading: { EmptyView() }
        )
    }
}

private extension View {
    /// A feed row of the mail sidebar's list: the row the list selects for
    /// its feed list, and named for a driver as the button row it replaces
    /// was. `.contain` keeps the folder chevron inside it reachable, as on
    /// the folder rows.
    func sidebarFeedRow(_ scope: RssItemScope, identifier: String) -> some View {
        sidebarFeedRow(scope)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

/// The folder tree's rows as `Button`s, for a list whose selection belongs
/// to something else (the mail sidebar's folders).
struct FeedSidebarRowsView<RowMenu: View>: View {
    let rows: [FeedSidebarRow]
    @Binding var selection: RssItemScope?
    let toggleCollapse: (String) -> Void
    let isCollapsed: (String) -> Bool
    @ViewBuilder let contextMenu: (FeedSidebarRow) -> RowMenu

    var body: some View {
        ForEach(rows) { row in
            Button {
                selection = row.scope
            } label: {
                FeedSidebarRowLabel(row: row, isSelected: selection == row.scope,
                                    isCollapsed: isCollapsed, toggleCollapse: toggleCollapse)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(row) }
            .listRowBackground(
                selection == row.scope
                    ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                    : nil
            )
            .accessibilityIdentifier("feed.row.\(row.id)")
        }
    }
}
