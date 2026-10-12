import SwiftUI
import CabalmailKit

/// Which `Feeds` menu item commands can currently do anything — the feed twin
/// of `MessageMenuAvailability`, answering the same rule (#985): a command is
/// enabled iff it has something to act on.
///
/// The item commands (Mark as Read/Unread, Flag/Unflag) are answered by the
/// mounted `FeedItemListView`, which acts on its selected row; the list is
/// single-selection, so the two fields agree today, and are kept apart for a
/// bulk selection to split them exactly as mail's are.
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
/// would leave AppKit to pick a winner (as `disposeChordHost` guards). So: the menu for the section in front of the user
/// (`WindowCommands.activeSection`) may be live, the other never is, whatever
/// its own availability says. On the wide layouts the two availabilities are
/// already exclusive (picking a feed scope clears the mail selection and
/// vice versa); on the tab layouts the menus read only the tab in front.
public enum SharedChordPolicy {
    /// Message ▸ Mark as Read/Unread and Flag/Unflag.
    static func mailItemsLive(_ mail: MessageMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .mail && mail.canActOnSelection
    }

    /// Feeds ▸ Mark as Read/Unread and Flag/Unflag.
    static func feedItemsLive(_ feeds: FeedMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .feeds && feeds.canActOnSelection
    }

    /// Mailbox ▸ Mark All as Read.
    public static func mailMarkAllReadLive(
        _ mailbox: MailboxMenuAvailability, activeSection: ResumeSession.Section
    ) -> Bool {
        activeSection == .mail && mailbox.canMarkAllRead
    }

    /// Feeds ▸ Mark All as Read.
    static func feedMarkAllReadLive(_ feeds: FeedMenuAvailability, activeSection: ResumeSession.Section) -> Bool {
        activeSection == .feeds && feeds.canMarkAllRead
    }
}

private struct FeedMenuAvailabilityReporter: ViewModifier {
    @Environment(\.windowCommands) private var commands
    @Environment(\.commandTab) private var tab
    @State private var reporter = UUID()
    /// Nil while this surface hosts no feed reader (a compact `MailRootView`).
    let availability: FeedMenuAvailability?

    func body(content: Content) -> some View {
        content
            .onAppear { if let availability { commands?.report(availability, in: tab, by: reporter) } }
            .onChange(of: availability) { _, new in
                if let new {
                    commands?.report(new, in: tab, by: reporter)
                } else {
                    commands?.withdrawFeedReport(in: tab, by: reporter)
                }
            }
            .onDisappear { commands?.withdrawFeedReport(in: tab, by: reporter) }
    }
}

private struct ActiveSectionReporter: ViewModifier {
    @Environment(\.windowCommands) private var commands
    /// Nil for a layout that does not decide the section (a `MailRootView`
    /// that hosts no feeds): it leaves the last answer alone.
    let section: ResumeSession.Section?

    func body(content: Content) -> some View {
        content.onChange(of: section, initial: true) { _, new in
            if let new { commands?.reportedSection = new }
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

    /// Publishes which section the wide split shows (`WindowCommands.activeSection`),
    /// so the menus that share a chord are never both enabled (`SharedChordPolicy`).
    func reportsActiveSection(_ section: ResumeSession.Section?) -> some View {
        modifier(ActiveSectionReporter(section: section))
    }
}
