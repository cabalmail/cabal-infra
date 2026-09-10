import SwiftUI
import CabalmailKit

/// The Feeds section of the mail sidebar (wide layouts) and the whole
/// sidebar of the Feeds tab (compact / visionOS): the folder tree with
/// subscriptions as leaves, unread badges, collapse chevrons, and a
/// selection that drives the item list.
///
/// Rows are `Button`s, not `List` selection, when they live inside the mail
/// sidebar's `List(selection: $folder)`: one list carries one selection
/// type, and the mail folders own it. The standalone `FeedSidebarList`
/// below uses native selection.
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

/// One row's label: indentation, chevron (folders), icon, title, badge.
struct FeedSidebarRowLabel: View {
    let row: FeedSidebarRow
    let isSelected: Bool
    let isCollapsed: (String) -> Bool
    let toggleCollapse: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if case .folder(let folder) = row.kind {
                Button {
                    toggleCollapse(folder.folderId)
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isCollapsed(folder.folderId) ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .opacity(row.hasChildren ? 1 : 0)
                }
                .buttonStyle(.borderless)
                .disabled(!row.hasChildren)
                .accessibilityLabel(isCollapsed(folder.folderId) ? "Expand \(folder.name)" : "Collapse \(folder.name)")
                Image(systemName: "folder")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(ColorTokens.accentForestFg))
            } else {
                Color.clear.frame(width: 14, height: 14)
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(ColorTokens.accentForestFg))
            }
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(row.unread > 0 || isSelected ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(Color.primary.opacity(0.7)))
            Spacer(minLength: 4)
            if row.unread > 0 {
                Text("\(row.unread)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .accessibilityLabel("\(row.unread) unread")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
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
    @State private var filter = ""

    var body: some View {
        List(selection: $selection) {
            if let model {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ColorTokens.dangerFg)
                        .font(.footnote)
                }
                if model.hasLoaded, !model.hasSubscriptions {
                    ContentUnavailableView {
                        Label("No feeds yet", systemImage: "dot.radiowaves.up.forward")
                    } description: {
                        Text("Subscribe to a feed to start reading here.")
                    } actions: {
                        Button("Subscribe to a Feed…") { actions.subscribe() }
                            .disabled(management == nil)
                    }
                    .listRowSeparator(.hidden)
                } else {
                    Label("All Feeds", systemImage: "tray.full")
                        .badge(FeedSidebarRows.totalUnread(model.unreadCounts))
                        .tag(RssItemScope.all)
                        .contextMenu {
                            FeedSidebarContextMenu(scope: .all, row: nil, actions: actions, management: management)
                        }
                    ForEach(model.rows(collapsed: collapsed, filter: filter)) { row in
                        FeedSidebarRowLabel(row: row, isSelected: selection == row.scope,
                                            isCollapsed: { collapsed.contains($0) },
                                            toggleCollapse: toggleCollapse)
                            .tag(row.scope)
                            .contextMenu {
                                FeedSidebarContextMenu(scope: row.scope, row: row, actions: actions,
                                                       management: management)
                            }
                    }
                }
            } else {
                ProgressView("Loading feeds…")
            }
        }
        .navigationTitle("Feeds")
        .searchable(text: $filter, prompt: "Filter feeds")
        .toolbar {
            ToolbarItem {
                FeedAddMenu(actions: actions, management: management)
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
        .refreshable { await model?.refresh() }
        .feedManagementSheets(actions, management: management, folders: model?.folders ?? [],
                              subscriptions: model?.subscriptions ?? [], selection: $selection,
                              handlesCommands: true, onRefresh: { Task { await model?.refresh() } })
        .task {
            guard model == nil, let client = appState.client else { return }
            management = FeedManagementViewModel(client: client)
            let model = FeedSidebarViewModel(client: client)
            self.model = model
            await model.load()
            await model.refresh()
        }
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
