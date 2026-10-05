import SwiftUI
import CabalmailKit

/// Bottom-pinned banner that appears whenever the user is viewing an
/// unsubscribed folder. Subscription is the user's signal to the system
/// that they want a folder kept current; without it, the message list
/// stays at whatever the user last saw and no background poll runs. The
/// banner makes that contract visible and gives them a one-tap escape
/// for the times they do want a current view.
///
/// Whether the folder *is* unsubscribed is decided by
/// `UnsubscribedBannerPolicy` against `AppState.subscribedFolderPaths`,
/// not by `folder.isSubscribed`: the selection can hold a stand-in
/// `Folder(path:)` (resume-position toast, push-notification tap,
/// Spotlight, Siri) whose flag is a default, and the banner used to
/// call a subscribed folder unsubscribed on every one of those routes.
///
/// Lives in `safeAreaInset(edge: .bottom)`, which extends the list's
/// scroll inset rather than overlaying the bottom row — so the last
/// envelope still scrolls above the banner and the row-level
/// `ensureLoaded(around:)` paging hook still fires.
///
/// That inset also puts the banner's *ideal* height into the window's
/// minimum content height, which is why the sentence carries a line
/// limit (`UnsubscribedBannerPolicy.messageLineLimit`) and not just
/// `.fixedSize` — see #1355.
extension MessageListView {
    @ViewBuilder
    func unsubscribedFolderBanner(model: MessageListViewModel) -> some View {
        UnsubscribedBannerRow(isRefreshing: unsubscribedRefreshInFlight) {
            Task { await refreshUnsubscribedFolder(model: model) }
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

/// The banner as its own view, so the line-limit rule that keeps it out of the
/// window's minimum height has a unit-test seam: this is the exact view
/// `safeAreaInset` mounts, and a test can measure its ideal height at a
/// proposed width the way the window does (#1355).
///
/// `lineLimit` is a parameter only so a test can measure the bounded and
/// unbounded shapes side by side; every caller takes the default.
struct UnsubscribedBannerRow: View {
    let isRefreshing: Bool
    var lineLimit: Int? = UnsubscribedBannerPolicy.messageLineLimit
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(.secondary)
            Text("This unsubscribed folder is not kept up-to-date automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                // Kept: this is what lets the sentence wrap to the lines the
                // limit allows instead of truncating to one at a narrow column.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: refresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise")
                        .accessibilityLabel("Refresh folder")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
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
}
