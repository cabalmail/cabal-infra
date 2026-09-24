import SwiftUI
import CabalmailKit

/// Which `Feeds` menu item commands can currently do anything — the feed twin
/// of `MessageMenuAvailability`, answering the same rule (#985): a command is
/// enabled iff it has something to act on.
///
/// The item commands (Mark as Read/Unread, Flag/Unflag) are answered by the
/// mounted `FeedItemListView`, which acts on its selected row; the feed list
/// is single-selection and the selected row is the open item, so the two
/// fields agree today. They are kept apart anyway because the bulk-selection
/// phase of the cross-media plan (Phase 3) splits them exactly as mail's are.
struct FeedMenuAvailability: Equatable {
    /// Rows the feed list has selected.
    var selectedCount: Int
    /// Whether an item is open in the feed reader.
    var hasOpenItem: Bool
    /// Whether a feed scope (a feed, a folder, All Feeds) is on screen, which
    /// is what Mark All as Read names and acts on.
    var hasScope: Bool

    /// Nothing selected, nothing open, no scope: the signed-out and launch
    /// state, and every state where the feed reader is not mounted.
    static let none = FeedMenuAvailability(selectedCount: 0, hasOpenItem: false, hasScope: false)

    /// Mark as Read/Unread and Flag/Unflag act on the selection, else the
    /// open item — `MessageMenuAvailability.canActOnSelection`'s rule.
    var canActOnSelection: Bool { selectedCount > 0 || hasOpenItem }

    /// Mark All as Read needs a scope to name in its confirmation.
    var canMarkAllRead: Bool { hasScope }
}

/// Which section's menu owns the chords the Message / Mailbox and Feeds
/// menus declare twice: ⌘T (mark read/unread), ⌘⇧8 (flag/unflag) and ⌥⌘T
/// (mark all read).
///
/// A menu key equivalent fires app-wide, so two enabled items on one chord
/// would leave AppKit to pick a winner — the failure the dispose chord's
/// single-host rule already guards against (`disposeChordHost`). The rule
/// here is by section: the menu for the section in front of the user
/// (`AppState.activeSection`) may be live, the other never is, whatever its
/// own availability says. On the wide layouts the two availabilities are
/// already exclusive (picking a feed scope clears the mail selection and
/// vice versa); the compact tabs are where both can be non-empty at once,
/// since each tab keeps its selection while the other is in front.
enum SharedChordPolicy {
    /// Message ▸ Mark as Read/Unread and Flag/Unflag.
    static func mailItemsLive(_ mail: MessageMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .mail && mail.canActOnSelection
    }

    /// Feeds ▸ Mark as Read/Unread and Flag/Unflag.
    static func feedItemsLive(_ feeds: FeedMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .feeds && feeds.canActOnSelection
    }

    /// Mailbox ▸ Mark All as Read.
    static func mailMarkAllReadLive(_ mailbox: MailboxMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .mail && mailbox.canMarkAllRead
    }

    /// Feeds ▸ Mark All as Read.
    static func feedMarkAllReadLive(_ feeds: FeedMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .feeds && feeds.canMarkAllRead
    }
}

private struct FeedMenuAvailabilityReporter: ViewModifier {
    @Environment(AppState.self) private var appState
    /// Nil when this surface does not host the feed reader in its current
    /// layout (a `MailRootView` inside the compact tabs): it then reports
    /// nothing, so it cannot overwrite the Feeds tab's own report.
    let availability: FeedMenuAvailability?

    func body(content: Content) -> some View {
        content
            .onChange(of: availability, initial: true) { _, new in
                if let new { appState.feedMenuAvailability = new }
            }
            .onDisappear {
                if availability != nil { appState.feedMenuAvailability = .none }
            }
    }
}

private struct ActiveSectionReporter: ViewModifier {
    @Environment(AppState.self) private var appState
    /// Nil for a layout that does not decide the section (a utility tab, a
    /// `MailRootView` that hosts no feeds): it leaves the last answer alone.
    let section: ResumeSession.Section?

    func body(content: Content) -> some View {
        content.onChange(of: section, initial: true) { _, new in
            if let new { appState.activeSection = new }
        }
    }
}

extension View {
    /// Publishes what the `Feeds` menu can act on from this surface — the one
    /// that owns both the feed scope and the item selection (`MailRootView`
    /// on the wide layouts, `FeedRootView` on the compact ones). `hosts` is
    /// false for a layout that does not show feeds here at all.
    func reportsFeedMenuAvailability(
        selectedCount: Int,
        hasOpenItem: Bool,
        hasScope: Bool,
        hosts: Bool = true
    ) -> some View {
        modifier(FeedMenuAvailabilityReporter(
            availability: hosts
                ? FeedMenuAvailability(selectedCount: selectedCount, hasOpenItem: hasOpenItem, hasScope: hasScope)
                : nil
        ))
    }

    /// Publishes which section is in front (`AppState.activeSection`), so the
    /// menus that share a chord are never both enabled (`SharedChordPolicy`).
    func reportsActiveSection(_ section: ResumeSession.Section?) -> some View {
        modifier(ActiveSectionReporter(section: section))
    }
}
