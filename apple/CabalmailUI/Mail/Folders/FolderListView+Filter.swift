import SwiftUI
import CabalmailKit

/// The sidebar's filter pills and tree affordances, split off from
/// `FolderListView` so the main struct body stays under the SwiftLint cap.
/// Same-type extensions in the same module share `private` scope with the
/// original declaration, so these see the `@AppStorage` keys as if inline.
extension FolderListView {
    // MARK: - Mail

    /// The two pill toggles as one value (see `FolderListFilter`).
    var folderFilter: FolderListFilter {
        FolderListFilter(subscribed: filterSubscribed, unread: filterUnread)
    }

    func selectFolderPill(_ pill: FolderListFilter.Pill) {
        let next = folderFilter.toggled(pill)
        filterSubscribed = next.subscribed
        filterUnread = next.unread
    }

    /// The pill row above the mail tree: the Subscribed and Unread toggles
    /// (both off draws every folder), and the Expand all / Collapse all
    /// buttons on the trailing edge. Same chrome as the message list's row
    /// of pills.
    var mailFilterPillRow: some View {
        SidebarFilterPillRow(
            pills: FolderListFilter.Pill.allCases.map { pill in
                SidebarFilterPill(id: pill.rawValue, label: pill.label, isOn: folderFilter.isOn(pill)) {
                    selectFolderPill(pill)
                }
            },
            identifierPrefix: "folder.filter",
            expansion: SidebarFilterPillRow.Expansion(
                hasCollapsible: !collapsibleFolderPaths.isEmpty,
                expandAll: { setAllFoldersCollapsed(false) },
                collapseAll: { setAllFoldersCollapsed(true) }
            )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The text filter and the pills, both applied. `selection` is exempt
    /// from the pills (never from the text filter — typing is deliberate).
    func filteredFolders(_ folders: [Folder]) -> [Folder] {
        let byPills = folderFilter.apply(
            to: folders,
            unreadCounts: appState.folderUnreadCounts,
            selection: selection?.path
        )
        let needle = activeFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return byPills }
        return byPills.filter { FolderListFilter.matches($0, needle: needle) }
    }

    /// The tree's last row when the pills are suppressing matches the user
    /// typed for (#1662): a button that turns both pills off, so the find
    /// is one click from its answer. Nothing at all when there is nothing to
    /// say, or when `shown` is false because the Mail section is collapsed.
    /// `visible` is `filteredFolders(folders)`, passed in rather than
    /// recomputed so the row cannot disagree with the tree above it. Not a
    /// `ContentUnavailableView`: this row also appears *under* a non-empty
    /// tree, where nothing is unavailable.
    @ViewBuilder
    func folderFilterHintRow(_ folders: [Folder], visible: [Folder], shown: Bool = true) -> some View {
        if shown, let hint = folderFilter.hint(for: folders, visible: visible, needle: activeFilterText) {
            Button {
                filterSubscribed = FolderListFilter.unfiltered.subscribed
                filterUnread = FolderListFilter.unfiltered.unread
            } label: {
                Label(hint.label, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("folder.filter.hint")
        }
    }

    /// What `walkAllCountsIfNeeded` is observed against: the pill state and
    /// whether there is a list to walk yet.
    var allCountsWalkKey: String {
        "\(folderFilter.needsEveryCount):\(model?.folders.count ?? 0)"
    }

    /// The Unread pill without Subscribed needs a count for every folder.
    /// Once per session, plus each manual refresh (which walks itself).
    func walkAllCountsIfNeeded() {
        guard folderFilter.needsEveryCount, let model, !model.folders.isEmpty, !didWalkAllCounts else { return }
        didWalkAllCounts = true
        Task { await model.refreshAllCounts() }
    }

    var collapsibleFolderPaths: Set<String> {
        SidebarTreeExpansion.collapsibleFolderPaths(model?.folders ?? [])
    }

    /// Expand all / Collapse all on the mail tree. Collapse is computed over
    /// the full list, not the filtered one, so a later pill change finds the
    /// tree in one consistent state. The open folder's ancestors are still
    /// forced open by `FolderTree.visibleFolders`, so it never disappears.
    func setAllFoldersCollapsed(_ collapse: Bool) {
        collapsedPathsRaw = encodeCollapsed(
            SidebarTreeExpansion.collapsed(all: collapsibleFolderPaths, collapse: collapse)
        )
    }

    /// A Mailbox / Feeds menu request. The mail pair is always ours; the
    /// feed pair only when the Feeds section lives in this sidebar (wide
    /// layouts) — on compact the Feeds tab's `FeedSidebarList` answers.
    func applySidebarTreeCommand(_ command: SidebarTreeCommand) {
        if command.isMail {
            setAllFoldersCollapsed(command.collapses)
        } else if feedSelection != nil {
            setAllFeedFoldersCollapsed(command.collapses)
        }
    }

    // MARK: - Feeds (wide layouts)

    /// The Feeds section's pill (`feedFilter` is the section's text filter).
    var feedListFilter: FeedListFilter {
        FeedListFilter(rawValue: feedFilterRaw) ?? FeedListFilter.defaultForFeeds
    }

    /// The Feeds section's pill row: the Unread toggle, plus the feed tree's
    /// Expand all / Collapse all. Drawn as the section's first row.
    func feedFilterPillRow(_ feedModel: FeedSidebarViewModel) -> some View {
        SidebarFilterPillRow(
            pills: [
                SidebarFilterPill(id: FeedListFilter.unread.rawValue, label: FeedListFilter.pillLabel,
                                  isOn: feedListFilter.unreadOnly) {
                    feedFilterRaw = feedListFilter.toggled.rawValue
                },
            ],
            identifierPrefix: "feed.filter",
            expansion: SidebarFilterPillRow.Expansion(
                hasCollapsible: !collapsibleFeedFolderIds.isEmpty,
                expandAll: { setAllFeedFoldersCollapsed(false) },
                collapseAll: { setAllFeedFoldersCollapsed(true) }
            )
        )
        .listRowSeparator(.hidden)
    }

    var collapsibleFeedFolderIds: Set<String> {
        SidebarTreeExpansion.collapsibleFeedFolderIds(
            folders: feedModel?.folders ?? [],
            subscriptions: feedModel?.subscriptions ?? []
        )
    }

    func setAllFeedFoldersCollapsed(_ collapse: Bool) {
        feedsCollapsedRawAccessor = SidebarTreeExpansion.collapsed(all: collapsibleFeedFolderIds, collapse: collapse)
            .sorted()
            .joined(separator: "\n")
    }
}
