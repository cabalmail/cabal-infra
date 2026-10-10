import SwiftUI
import CabalmailKit

// The feed sidebar's pieces: the row label both sidebars draw, and the Feeds
// tab's standalone sidebar. The list itself, which the mail sidebar's Feeds
// section draws too, is `FeedSidebarContent`.

/// One row's label: indentation, chevron (folders), icon, title, badge.
struct FeedSidebarRowLabel: View {
    let row: FeedSidebarRow
    let isSelected: Bool
    let isCollapsed: (String) -> Bool
    let toggleCollapse: (String) -> Void
    /// The badge follows the Reading preference the mail folders read
    /// (unread, total, or both); feed rows used to show unread only.
    @Environment(Preferences.self) private var preferences

    var body: some View {
        SidebarTreeRowLabel(
            title: row.title,
            systemImage: Self.symbol(for: row.kind),
            depth: row.depth,
            disclosure: disclosure,
            hasUnread: row.unread > 0,
            isSelected: isSelected,
            titleLineLimit: 1
        ) {
            healthBadge
            // The mail rows' capsule and rule (`CountBadge`): nothing is
            // drawn when the mode hides the count.
            CountBadge(display: preferences.folderCountDisplay, unread: row.unread, total: row.total)
        }
        // The whole row is the hit target of the wide layout's row button,
        // spacer included.
        .contentShape(Rectangle())
    }

    /// A folder row with rows under it gets the chevron; anything else keeps
    /// the slot empty.
    private var disclosure: SidebarTreeDisclosure? {
        guard case .folder(let folder) = row.kind, row.hasChildren else { return nil }
        return .init(isCollapsed: isCollapsed(folder.folderId), name: folder.name,
                     toggle: { toggleCollapse(folder.folderId) })
    }

    /// The tree's glyphs: a folder (All Feeds included) or a feed.
    static func symbol(for kind: FeedSidebarRow.Kind) -> String {
        if case .subscription = kind { return "dot.radiowaves.up.forward" }
        return "folder"
    }

    /// The fetcher's health for a subscription row: a warning mark from
    /// three consecutive failures, a stop mark once it has given up. Silent
    /// otherwise, and never on folders (their feeds carry their own).
    @ViewBuilder
    private var healthBadge: some View {
        if case .subscription(let sub) = row.kind {
            let level = FeedHealth.level(for: sub.feed)
            if let symbol = level.symbol, let summary = level.summary {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(level == .stopped ? ColorTokens.dangerFg : ColorTokens.warningFg)
                    .help(summary)
                    .accessibilityLabel(summary)
                    .accessibilityIdentifier("feed.health.\(sub.subscriptionId)")
            }
        }
    }
}

/// Standalone Feeds sidebar (the Feeds tab on iPhone and visionOS): the same
/// rows with native list selection, plus a header for refresh.
struct FeedSidebarList: View {
    @Binding var selection: RssItemScope?
    @Environment(AppState.self) private var appState
    @State private var model: FeedSidebarViewModel?
    @State private var management: FeedManagementViewModel?
    @State private var actions = FeedManagementActions()
    @AppStorage("cabalmail.feeds.collapsedFolders") private var collapsedRaw = ""
    /// The Unread pill (`FeedListFilter`): sticky per device, never synced;
    /// the wide sidebar's Feeds section reads the same key.
    @AppStorage("cabalmail.feeds.filter") private var filterRaw = FeedListFilter.defaultForFeeds.rawValue
    @State private var filter = ""

    private var listFilter: FeedListFilter {
        FeedListFilter(rawValue: filterRaw) ?? FeedListFilter.defaultForFeeds
    }

    var body: some View {
        VStack(spacing: 0) {
            pillRow
            list
        }
        .navigationTitle("Feeds")
        #if !os(macOS)
        // In the compact Feeds tab the Cabalmail mark stands in for the
        // title, as on the Mail tab; the string stays for VoiceOver and the
        // back button (see `SidebarBranding.swift`).
        .compactBrandMarkTitle(accessibilityTitle: "Feeds")
        #endif
        .searchable(text: $filter, prompt: "Filter feeds")
        .toolbar {
            ToolbarItem {
                FeedAddMenu(actions: actions, management: management)
            }
            ToolbarItem {
                FeedExportButton(actions: actions, management: management)
            }
            ToolbarItem {
                Button {
                    Task { await model?.refresh() }
                } label: {
                    RefreshActivityIcon(isLoading: model?.isRefreshing ?? false)
                        .accessibilityLabel("Refresh feeds")
                }
                .disabled(model == nil || model?.isRefreshing == true)
                .accessibilityIdentifier("feeds.refresh")
            }
        }
        .feedManagementSheets(actions, management: management, folders: model?.folders ?? [],
                              subscriptions: model?.subscriptions ?? [], selection: $selection,
                              handlesCommands: true, onRefresh: { Task { await model?.refresh() } })
        // The Feeds menu's Expand all / Collapse all, from a tab behind too;
        // the mail pair is the Mail tab's to answer.
        .answersCommands(SidebarTreeCommand.allCases.map(WindowCommand.sidebarTree), whileBehind: true) { command in
            guard case .sidebarTree(let tree) = command, !tree.isMail else { return }
            setAllCollapsed(tree.collapses)
        }
        .task {
            if model == nil, let client = appState.client {
                management = FeedManagementViewModel(client: client)
                model = FeedSidebarViewModel(client: client)
            }
            // Every appearance, not only the first: a refresh cut short as
            // the sidebar left (a push, a tab switch) is owed, and this is
            // where it is paid (#1908). A no-op once one has finished.
            await model?.refreshIfNeeded()
        }
        // The tree and badges follow the store while the sidebar is up.
        .task(id: model.map(ObjectIdentifier.init)) {
            await model?.observe()
        }
    }

    /// The Unread toggle, plus the tree's Expand all / Collapse all — the
    /// same row the wide sidebar's Feeds section draws.
    private var pillRow: some View {
        SidebarFilterPillRow(
            pills: [
                SidebarFilterPill(id: FeedListFilter.unread.rawValue, label: FeedListFilter.pillLabel,
                                  isOn: listFilter.unreadOnly) {
                    filterRaw = listFilter.toggled.rawValue
                },
            ],
            identifierPrefix: "feed.filter",
            expansion: SidebarFilterPillRow.Expansion(
                hasCollapsible: !collapsible.isEmpty,
                expandAll: { setAllCollapsed(false) },
                collapseAll: { setAllCollapsed(true) }
            )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        List(selection: $selection) {
            if let model {
                FeedSidebarContent(
                    style: .listSelection, model: model, selection: $selection,
                    rows: model.rows(collapsed: collapsed, filter: filter,
                                     unreadOnly: listFilter.unreadOnly, keep: selection),
                    isCollapsed: { collapsed.contains($0) }, toggleCollapse: toggleCollapse,
                    actions: actions, management: management
                )
            } else {
                ProgressView("Loading feeds…")
            }
        }
        .refreshable { await model?.refresh() }
    }

    private var collapsible: Set<String> {
        SidebarTreeExpansion.collapsibleFeedFolderIds(
            folders: model?.folders ?? [],
            subscriptions: model?.subscriptions ?? []
        )
    }

    private func setAllCollapsed(_ collapse: Bool) {
        collapsedRaw = SidebarTreeExpansion.collapsed(all: collapsible, collapse: collapse)
            .sorted()
            .joined(separator: "\n")
    }

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    private func toggleCollapse(_ folderId: String) {
        var set = collapsed
        if set.contains(folderId) { set.remove(folderId) } else { set.insert(folderId) }
        collapsedRaw = set.sorted().joined(separator: "\n")
    }
}
