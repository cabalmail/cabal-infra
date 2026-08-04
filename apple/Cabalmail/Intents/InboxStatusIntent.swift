#if os(iOS)
import AppIntents
import CabalmailKit

/// "Check my Cabalmail inbox." Speaks the unread count and the newest
/// unread senders, and returns the count so Shortcuts can build on it.
struct InboxStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Inbox"
    static let description = IntentDescription(
        "Tells you how many unread messages your inbox has and who the latest are from.",
        categoryName: "Mail"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let client = try await IntentBridge.shared.activeClient()
        let unread: Int
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: "INBOX")
            unread = status.unseen ?? 0
        } catch {
            throw IntentError.friendly(error)
        }
        // Keep the app's badge state coherent when it's running; the 60s
        // poller reconciles any drift either way.
        IntentBridge.shared.appState?.setInboxUnread(unread)
        guard unread > 0 else {
            return .result(value: 0, dialog: "Your inbox has no unread messages.")
        }
        let senders = await latestUnreadSenders(client: client)
        return .result(value: unread, dialog: Self.dialog(unread: unread, senders: senders))
    }

    /// Display names of the newest unread senders, deduped, newest first.
    /// Best-effort — a search failure degrades to the bare count.
    private func latestUnreadSenders(client: CabalmailClient) async -> [String] {
        guard let result = try? await client.imapClient.searchEnvelopes(
            SearchQuery(folder: "INBOX", unread: true, limit: 5)
        ) else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for hit in result.envelopes {
            guard let from = hit.envelope.from.first else { continue }
            let name = from.displayName ?? "\(from.mailbox)@\(from.host)"
            if seen.insert(name).inserted { names.append(name) }
        }
        return Array(names.prefix(3))
    }

    static func dialog(unread: Int, senders: [String]) -> IntentDialog {
        let count = unread == 1 ? "1 unread message" : "\(unread) unread messages"
        guard let latest = senders.first else {
            return IntentDialog("You have \(count) in your inbox.")
        }
        let others = Array(senders.dropFirst())
        guard !others.isEmpty else {
            return IntentDialog("You have \(count) in your inbox. The latest is from \(latest).")
        }
        let more = ListFormatter.localizedString(byJoining: others)
        return IntentDialog(
            "You have \(count) in your inbox. The latest is from \(latest), with more from \(more)."
        )
    }
}
#endif
