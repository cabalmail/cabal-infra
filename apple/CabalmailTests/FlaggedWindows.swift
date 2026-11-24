import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// Real windows for the Flagged view's navigation tests: a `SceneNavigator`
/// over a real coordinator and resume session, with the trees a layout
/// mounts.
@MainActor
final class FlaggedWindows {
    /// A window on the tab layout: its Mail tab's stack and its Feeds
    /// tab's.
    struct Tabs {
        let navigator: SceneNavigator
        let mail: UUID
        let feeds: UUID
    }

    let coordinator: NavStateCoordinator
    private let suiteName: String
    private let defaults: UserDefaults

    let inbox = Folder(path: "INBOX", isSubscribed: true)
    let archive = Folder(path: "Archive", isSubscribed: true)

    let message = FlaggedRow.mail(
        Envelope(uid: 4, messageId: "<four@example.com>", subject: "m4", from: [], flags: [.flagged], folder: "Lists"),
        MessageRef(folder: "Lists", uid: 4, messageId: "<four@example.com>")
    )
    let article = FlaggedRow.feed(
        RssItem(feedId: "f", subscriptionId: "s", itemId: "a", sortKey: "a", isFavorite: true)
    )

    init() throws {
        suiteName = "FlaggedWindows.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        coordinator = NavStateCoordinator(
            client: try TestFixtures.makeClient(imap: FakeImapClient()), clientID: "this-install",
            store: ResumeSessionStore(defaults: defaults)
        )
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeNavigator(stored: AppRoute? = nil, seed: ResumeSession.Section = .mail) -> SceneNavigator {
        let coordinator = coordinator
        return SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: seed, storedRoute: stored,
            feedsLaunchTarget: { _, _ in nil }
        )
    }

    /// A window on the wide layout, landed on INBOX.
    func wideWindow(stored: AppRoute? = nil) async -> (navigator: SceneNavigator, tree: UUID) {
        let navigator = makeNavigator(stored: stored)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: true)
        navigator.foldersLoaded([inbox, archive])
        return (navigator, tree)
    }

    /// A window on the tab layout with its Mail tab's stack and its Feeds
    /// tab's stack both mounted.
    func tabWindow() async -> Tabs {
        let navigator = makeNavigator()
        let mail = UUID()
        let feeds = UUID()
        await navigator.mailTreeAppeared(mail, isWide: false, startsOnFolderList: true)
        navigator.foldersLoaded([inbox, archive])
        await navigator.feedTreeAppeared(feeds)
        return Tabs(navigator: navigator, mail: mail, feeds: feeds)
    }
}
