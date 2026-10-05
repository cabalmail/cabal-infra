import SwiftUI
import CabalmailKit
import CabalmailUI

/// Mirrors the outbox's failed entries (sends that ran out of retries) into
/// view state for `FailedSendBanner`. Owned by `SignedInRootView`, which
/// keeps it observing for the session's lifetime.
///
/// Before this existed a queued message that exhausted its retries was
/// deleted with only a log line, so the sender never learned it hadn't gone
/// (audit F8). The outbox now keeps such an entry, marked failed, and this
/// is where the user hears about it.
@Observable
@MainActor
final class FailedSendMonitor {
    private(set) var failed: [Outbox.Entry] = []
    /// Entries the user chose to keep without retrying. The banner stays
    /// down until a different set of messages has failed; a relaunch shows
    /// it again.
    private var keptIDs: Set<UUID> = []

    /// The failed entries the banner should show.
    var visible: [Outbox.Entry] {
        failed.filter { !keptIDs.contains($0.id) }
    }

    func observe(_ client: CabalmailClient?) async {
        guard let client else { return }
        for await entries in await client.outbox.changes() {
            failed = entries.filter(\.isFailed)
        }
    }

    func keepForLater() {
        keptIDs = Set(failed.map(\.id))
    }
}

/// The root status overlay's banner for sends that failed for good: Retry
/// puts them back in the queue, and closing the banner asks whether to
/// discard them or keep them for later.
struct FailedSendBanner: View {
    let monitor: FailedSendMonitor
    let client: CabalmailClient
    @State private var confirmingDiscard = false

    var body: some View {
        let entries = monitor.visible
        BannerView(
            icon: "exclamationmark.triangle.fill",
            text: Self.text(for: entries),
            tint: ColorTokens.dangerFg,
            actionTitle: "Retry",
            actionIcon: "arrow.clockwise",
            onAction: { retry(entries) },
            onDismiss: { confirmingDiscard = true }
        )
        .accessibilityIdentifier("banner.failedSend")
        .confirmationDialog(
            Self.discardTitle(count: entries.count),
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { discard(entries) }
            Button("Keep for Later", role: ConfirmationDialogPolicy.backOutRole) {
                monitor.keepForLater()
            }
        } message: {
            Text("Discarding can't be undone.")
        }
    }

    private func retry(_ entries: [Outbox.Entry]) {
        Task {
            for entry in entries {
                try? await client.retryFailedSend(id: entry.id)
            }
        }
    }

    private func discard(_ entries: [Outbox.Entry]) {
        Task {
            for entry in entries {
                try? await client.discardFailedSend(id: entry.id)
            }
        }
    }

    /// "Couldn't send “Lunch”." for one message; a count for several.
    static func text(for entries: [Outbox.Entry]) -> String {
        guard entries.count == 1, let entry = entries.first else {
            return "\(entries.count) messages couldn't be sent."
        }
        let subject = entry.message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty
            ? "A message with no subject couldn't be sent."
            : "Couldn't send “\(subject)”."
    }

    static func discardTitle(count: Int) -> String {
        count == 1 ? "Discard the unsent message?" : "Discard \(count) unsent messages?"
    }
}
