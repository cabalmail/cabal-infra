import Foundation
import CabalmailKit

/// What one main window writes to the per-install resume session and the
/// server cursor, and whether it may.
///
/// Only the window the user last used (`AppState.lastActiveMainWindow`), or
/// every window while none is named, records the place a relaunch, a new
/// window and another device resume from. Before, every window recorded, so
/// the place followed whichever window moved last, even one in the
/// background. Reading positions still record from every window: where the
/// user is in a message is the message's, whichever window shows it. When
/// another window becomes the one last used, it records its whole route
/// once (`handOver`), so the session and the cursor move to it.
///
/// Each `SceneNavigator` owns one; the readers reach it through the
/// navigator.
@MainActor
final class WindowRecorder {
    /// The window this records for: `MainWindowCommandScope`'s
    /// `commandWindowID`, the identity command targeting uses. Nil until the
    /// host sets it; a window with no identity does not record while another
    /// window is named.
    var windowID: UUID?

    private let coordinator: @MainActor () -> NavStateCoordinator?
    private let lastUsedWindow: @MainActor () -> UUID?

    /// - Parameters:
    ///   - coordinator: the session's `NavStateCoordinator`, read live.
    ///   - lastUsedWindow: the window the user last used; nil when none is
    ///     recorded, and in tests and previews, where every window records.
    init(
        coordinator: @escaping @MainActor () -> NavStateCoordinator?,
        lastUsedWindow: @escaping @MainActor () -> UUID? = { nil }
    ) {
        self.coordinator = coordinator
        self.lastUsedWindow = lastUsedWindow
    }

    /// Whether this window records: it is the one last used, or none is.
    var isRecording: Bool {
        guard let lastUsed = lastUsedWindow() else { return true }
        return lastUsed == windowID
    }

    /// The session's coordinator while this window records, else nil: what
    /// a restore primes and a landing arms.
    var recording: NavStateCoordinator? {
        isRecording ? coordinator() : nil
    }

    // MARK: The place

    func folder(_ path: String) { recording?.recordFolder(path) }

    func message(_ ref: MessageRef) { recording?.recordMessage(ref) }

    func noMessage(folderPath: String) { recording?.recordNoMessage(folderPath: folderPath) }

    func section(_ section: ResumeSession.Section) { recording?.noteSection(section) }

    func feedScope(_ scope: RssItemScope?) { recording?.recordFeedScope(scope) }

    func feedItem(_ item: RssItem?) { recording?.recordFeedItem(item) }

    /// Where the window's folder list is scrolled (`ListAnchor`; nil at the
    /// top), for the next launch.
    func listPlace(_ anchor: ListAnchor?, in folderPath: String) {
        recording?.recordListAnchor(anchor, folderPath: folderPath)
    }

    // MARK: Reading positions

    /// A mail reader's scroll capture. The recording window moves the cursor
    /// and the position cache together, while the cursor is on the message
    /// (`NavStateCoordinator.recordMessageScroll`). Another window keeps the
    /// position only, and only for the message open in it (`isOpenHere`), as
    /// the cursor guard keeps a search result's out of the recording window.
    func messageScroll(_ ref: MessageRef, position: ReadingPosition, atTop: Bool, isOpenHere: Bool) {
        guard let coordinator = coordinator() else { return }
        if isRecording {
            coordinator.recordMessageScroll(ref, position: position, atTop: atTop)
        } else if isOpenHere {
            coordinator.savePosition(for: ref, position: position, atTop: atTop)
        }
    }

    /// A feed reader's scroll capture: the position from any window, the
    /// cursor from the recording one.
    func feedScroll(itemID: String, capture: ScrollCapture) {
        coordinator()?.recordFeedScroll(itemID: itemID, capture: capture, movesCursor: isRecording)
    }

    // MARK: Hand-over

    /// This window became the one last used: record where it is once, so the
    /// session and the cursor are where this window is. The section it is
    /// not in goes first, so the session's section and the cursor's kind
    /// end on this window's. A half the window has not opened (`nil`: no
    /// folder, no feed list, or mail a window has not shown) is left as the
    /// session has it, for the round trip the session keeps: a place a
    /// restored window holds only in its stored route has not been opened.
    /// `listPlace` is where the window's folder list is scrolled, which
    /// replaces the place the window last used left for the same folder.
    func handOver(
        section: ResumeSession.Section, mail: AppRoute.Mail?, listPlace: ListAnchor?,
        feedScope: RssItemScope?, feedItem: RssItem?
    ) {
        guard let coordinator = recording else { return }
        if section == .feeds {
            recordMail(mail, listPlace: listPlace, on: coordinator)
            recordFeeds(feedScope, item: feedItem, on: coordinator)
        } else {
            recordFeeds(feedScope, item: feedItem, on: coordinator)
            recordMail(mail, listPlace: listPlace, on: coordinator)
        }
        coordinator.noteSection(section)
    }

    /// The mail half: the folder and where its list is scrolled, the open
    /// message, and the message's saved reading position on the cursor, as
    /// reopening a feed item carries its own (`recordFeedItem`).
    private func recordMail(_ mail: AppRoute.Mail?, listPlace: ListAnchor?, on coordinator: NavStateCoordinator) {
        guard let path = mail?.folderPath else { return }
        coordinator.recordFolder(path)
        coordinator.recordListAnchor(listPlace?.folderPath == path ? listPlace : nil, folderPath: path)
        guard let ref = mail?.message else { return }
        coordinator.recordMessage(ref)
        if let position = coordinator.readingPosition(for: ref) {
            coordinator.recordMessageScroll(ref, position: position, atTop: false)
        }
    }

    private func recordFeeds(_ scope: RssItemScope?, item: RssItem?, on coordinator: NavStateCoordinator) {
        guard let scope else { return }
        coordinator.recordFeedScope(scope)
        if let item { coordinator.recordFeedItem(item) }
    }
}

// The navigator's side of recording, here rather than in `SceneNavigator.swift`
// so that file keeps to its length; everything it reads is readable from here.
extension SceneNavigator {
    /// - Parameters:
    ///   - windowID: the window's `commandWindowID`, when the host has it.
    ///   - stored: the window's place from its scene storage, already
    ///     checked against the account (`StoredRoute`): the route it starts
    ///     on, and where its folder list was scrolled, parked for that list.
    convenience init(appState: AppState, windowID: UUID? = nil, stored: StoredRoute? = nil) {
        self.init(
            coordinator: { [weak appState] in appState?.navCoordinator },
            hasClient: { [weak appState] in appState?.client != nil },
            seed: stored?.route.section ?? ResumeSessionStore.storedSection(),
            storedRoute: stored?.route,
            lastUsedWindow: { [weak appState] in appState?.lastActiveMainWindow },
            deepLinks: appState.deepLinks
        )
        self.windowID = windowID
        if let anchor = stored?.listPlace { restores.parkListAnchor(anchor) }
    }

    /// The window this navigator belongs to (`WindowRecorder.windowID`).
    var windowID: UUID? {
        get { recorder.windowID }
        set { recorder.windowID = newValue }
    }

    /// The window became the one the user last used (`WindowRecorder.handOver`):
    /// the folder it has open, if it has shown mail, and its feed list.
    func becameLastUsed() {
        recorder.handOver(
            section: route.section,
            mail: hasShownMail && selectedFolder != nil ? route.mail : nil, listPlace: listHold.place,
            feedScope: feeds.scope, feedItem: feeds.item
        )
    }

    /// A mail reader in this window captured its scroll position.
    func recordMessageScroll(_ ref: MessageRef, position: ReadingPosition, atTop: Bool) {
        recorder.messageScroll(ref, position: position, atTop: atTop, isOpenHere: route.mail.message == ref)
    }

    /// A feed reader in this window captured its scroll position.
    func recordFeedScroll(itemID: String, capture: ScrollCapture) {
        recorder.feedScroll(itemID: itemID, capture: capture)
    }
}
