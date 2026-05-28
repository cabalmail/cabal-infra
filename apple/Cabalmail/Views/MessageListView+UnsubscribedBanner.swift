import SwiftUI
import CabalmailKit

/// Bottom-pinned banner that appears whenever the user is viewing an
/// unsubscribed folder. Subscription is the user's signal to the system
/// that they want a folder kept current; without it, the message list
/// stays at whatever the user last saw and no background poll runs. The
/// banner makes that contract visible and gives them a one-tap escape
/// for the times they do want a current view.
///
/// Lives in `safeAreaInset(edge: .bottom)`, which extends the list's
/// scroll inset rather than overlaying the bottom row — so the last
/// envelope still scrolls above the banner and the row-level
/// `loadMoreIfNeeded(currentItem:)` paging hook still fires.
extension MessageListView {
    @ViewBuilder
    func unsubscribedFolderBanner(model: MessageListViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.secondary)
            Text("This unsubscribed folder is not kept up-to-date automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await refreshUnsubscribedFolder(model: model) }
            } label: {
                if unsubscribedRefreshInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise")
                        .accessibilityLabel("Refresh folder")
                }
            }
            .buttonStyle(.borderless)
            .disabled(unsubscribedRefreshInFlight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            // Hairline divider that matches list separators so the
            // banner reads as part of the list chrome rather than a
            // floating sheet.
            Divider()
        }
    }

    /// Refresh the envelope list AND the folder's STATUS counts in one
    /// gesture, so the badge in the sidebar advances together with the
    /// list of messages on screen.
    func refreshUnsubscribedFolder(model: MessageListViewModel) async {
        guard !unsubscribedRefreshInFlight else { return }
        unsubscribedRefreshInFlight = true
        defer { unsubscribedRefreshInFlight = false }
        async let listRefresh: () = model.refresh()
        async let statusRefresh: () = refreshFolderStatus()
        _ = await listRefresh
        _ = await statusRefresh
    }

    private func refreshFolderStatus() async {
        guard let client = appState.client else { return }
        if let status = try? await client.imapClient.status(path: folder.path) {
            appState.setFolderCounts(
                folderPath: folder.path,
                unread: status.unseen ?? 0,
                total: status.messages ?? 0
            )
        }
    }
}
