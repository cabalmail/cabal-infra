import SwiftUI
import Observation
import CabalmailKit

/// One main window's navigation: where the window is, held above the layout
/// switch so a size-class swap rebuilds only the layout.
///
/// `SignedInRootView` owns one per window in `@State`, the lowest view that
/// survives the swap between the compact tab tree and the regular split, and
/// hands it down in the environment. The route (`AppRoute`) names the place
/// by ID; beside it the navigator keeps the resolved `Folder`, `Envelope` and
/// `RssItem` the views still take, the compact column and tab, the sidebar's
/// fetched folders, and the landing flags. Before this, all of it was
/// `@State` on the views and went with each tree: a fold or a narrowed iPad
/// window re-landed the new tree from the per-install resume session, which
/// another window may have written since.
///
/// **Trees.** Each `MailRootView` instance is a tree with an identity of its
/// own (`mailTreeAppeared`), and so is visionOS's tab view, which has no
/// layout swap and so only ever one. The first tree in a window lands — on a
/// parked deep link (`DeepLinkRouter`), else the window's stored route (`StoredRoute`),
/// else the launch snapshot of the resume session. A tree built later by a
/// layout swap renders the window's route instead: the folder stays, and an
/// open message is re-parked in the window's own `WindowRestores`, so the new
/// list selects it once it has appeared and loaded. (A route with no folder
/// lands on the live session, as a rebuilt tree always did.) Until a tree has
/// taken over it sees no folder and no message, exactly as a fresh tree did
/// before, so its list mounts only after the restore is parked and a compact
/// stack is never handed a list and a reader in one update (#1664). Once a
/// new tree has appeared, writes from the tree a swap is tearing down are
/// dropped.
///
/// **Feeds** follow the same pattern with trees of their own: `FeedRootView`
/// (the Feeds tab on the compact layout and visionOS) and the wide
/// `MailRootView`, which hosts feeds beside mail (`feedTreeAppeared`,
/// `FeedNavigationState`). The wide split shows feeds while the window is in
/// the feeds section with a list open (`splitShowsFeeds`); mail in that split
/// leaves the compact Feeds tab's place where it was.
///
/// Every transition does what the view handler it replaced did, cursor
/// recording included, but only the window last used records
/// (`WindowRecorder`). The search model is the window's too
/// (`searchModel`), but whether the window is searching is the view's: a
/// transition that reads it takes `isSearching`. So is the folder list's
/// selection (`mailSelection(for:)`), which a swap hands to the new tree's
/// list when it is more than the open message.
@Observable
@MainActor
final class SceneNavigator {
    /// What this window writes to the resume session and the cursor, and
    /// whether it may (`WindowRecorder`); it holds the window's `windowID`.
    let recorder: WindowRecorder

    /// Whether the window shows the regular split rather than the compact
    /// tab tree. Set by the host as the layout changes, and by each tree as
    /// it appears.
    var layoutIsWide = false

    private(set) var route: AppRoute

    /// The sidebar's folder: the resolved value of `route.mail.folderPath`,
    /// the fetched `Folder` once the folder list has loaded (#1535). Trees
    /// read it through `folder(in:)`.
    private(set) var selectedFolder: Folder?

    /// The open message; read through `envelope(in:)`. Usually the route's
    /// message, but a search result while searching.
    private var selectedEnvelope: Envelope?

    /// Which column the collapsed navigation shows; read through
    /// `compactColumn(in:)`. Stored rather than derived from the route
    /// because backing out to the folder list leaves the folder selected.
    private var compactColumn: NavigationSplitViewColumn = .sidebar

    /// The window's place in the feed reader, read and written by the feed
    /// trees (`FeedNavigationState`).
    private(set) var feeds = FeedNavigationState()

    /// What this window's lists and reader take once they are ready.
    let restores = WindowRestores()

    /// The window's search model (`searchModel(client:preferences:mailStore:)`).
    @ObservationIgnored private var search: MessageListViewModel?

    /// The window's folder list: its selection and place (`FolderListHold`).
    let listHold = FolderListHold()

    /// Counts the feed banners this window has followed, so the wide split
    /// can end a search for one as it does for a feed pick (`navigateFeeds`).
    private(set) var feedNavigations = 0

    /// The compact layout's tab, or visionOS's. Seeded from the resume
    /// session when the window is created and kept from then on, so a swap
    /// to the regular split and back reopens the tab it left — the Search,
    /// Addresses and Settings tabs included. On the wide layout, which has
    /// no tab bar, it follows what the user does in the split (#1644).
    private(set) var compactTab: CompactTab

    /// The window's Settings and search across a change of layout shell.
    private(set) var shellHandOff = ShellHandOff()

    /// The sidebar's fetched folders, so a navigate request can select the
    /// real `Folder` the sidebar tags its row with rather than a stand-in
    /// (#1535).
    private(set) var loadedFolders: [Folder] = []

    /// Whether this window has landed: on the session's folder, provisionally,
    /// in the feed reader, or on a deep link. Never reset — a cleared
    /// selection later must not pull the user back to the landing.
    private(set) var didLand = false

    /// Set alongside a provisional landing and consumed by the folder list's
    /// first load, which swaps the fetched folder in (`foldersLoaded`).
    private(set) var awaitingLaunchReconcile = false

    /// Whether the window has shown mail since it was created: the regular
    /// split, or a tab of the mail section (Mail, or visionOS's Folders). A
    /// landing records its folder only once it has. visionOS lands at launch
    /// whichever tab is up, and its Mail tab, not yet built on a Feeds
    /// launch, used to record nothing; recording there would move the
    /// session out of Feeds and drop its open message. Once built, it
    /// recorded whatever tab was up, so this never goes back to false.
    private(set) var hasShownMail: Bool

    /// The tree that owns the window's folder, message and column
    /// (`TreeGate`).
    private var mailTrees = TreeGate()

    private let coordinator: @MainActor () -> NavStateCoordinator?
    private let hasClient: @MainActor () -> Bool
    /// The router deep links reach this window through (`open(_:)`).
    private let deepLinks: DeepLinkRouter
    /// A deep link's lookup in flight (`open(_:)`): the landing waits on it.
    @ObservationIgnored private var opening: Task<Void, Never>?
    private let feedsLaunchTarget: @MainActor (NavStateCoordinator, AppRoute.Feeds) async
        -> NavStateCoordinator.FeedLaunchTarget?

    /// - Parameters:
    ///   - coordinator: the session's `NavStateCoordinator`, read live
    ///     (sign-in and sign-out replace it).
    ///   - hasClient: whether a client is wired; the landing waits for one
    ///     because the message list cannot build its model without it.
    ///   - seed: the section a new window opens on — where the app last
    ///     was. Read from the stored session rather than the coordinator, so
    ///     building a navigator observes nothing (the host's initializer
    ///     runs inside its parent's body).
    ///   - storedRoute: the window's own route from its scene storage. It is
    ///     the route the window starts on, so the first frame has its tab,
    ///     and what its first landings reopen.
    ///   - lastUsedWindow: the window the user last used, which alone records
    ///     (`WindowRecorder`).
    ///   - deepLinks: the router this window takes deep links from; the
    ///     app's (`AppState.deepLinks`), or a test's own.
    ///   - feedsLaunchTarget: the feed scope and item a landing in feeds
    ///     reopens, given the window's stored feeds; the coordinator's
    ///     local-store lookup, replaceable in tests.
    init(
        coordinator: @escaping @MainActor () -> NavStateCoordinator?,
        hasClient: @escaping @MainActor () -> Bool,
        seed: ResumeSession.Section? = ResumeSessionStore.storedSection(),
        storedRoute: AppRoute? = nil,
        lastUsedWindow: @escaping @MainActor () -> UUID? = { nil },
        deepLinks: DeepLinkRouter = DeepLinkRouter(),
        feedsLaunchTarget: @escaping @MainActor (NavStateCoordinator, AppRoute.Feeds) async
            -> NavStateCoordinator.FeedLaunchTarget? = { await $0.consumeFeedsLaunchTarget(stored: $1) }
    ) {
        self.coordinator = coordinator
        self.hasClient = hasClient
        self.deepLinks = deepLinks
        self.feedsLaunchTarget = feedsLaunchTarget
        recorder = WindowRecorder(coordinator: coordinator, lastUsedWindow: lastUsedWindow)
        let section = storedRoute?.section ?? seed ?? .mail
        route = storedRoute ?? AppRoute(section: section)
        compactTab = CompactTab.initial(for: section)
        hasShownMail = section == .mail
    }

    // MARK: Trees

    /// The sidebar folder as `tree` should draw it: none until the tree has
    /// taken over (see the type's doc).
    func folder(in tree: UUID) -> Folder? {
        mailTrees.shows(tree) ? selectedFolder : nil
    }

    /// The open message as `tree` should draw it: none until the tree has
    /// taken over.
    func envelope(in tree: UUID) -> Envelope? {
        mailTrees.shows(tree) ? selectedEnvelope : nil
    }

    /// The compact column as `tree` should draw it: the folder list until the
    /// tree has taken over.
    func compactColumn(in tree: UUID) -> NavigationSplitViewColumn {
        mailTrees.shows(tree) ? compactColumn : .sidebar
    }

    /// A mail tree appeared: a `MailRootView`, or visionOS's tab view, which
    /// lands whichever tab it opens on. The first tree in the window lands;
    /// a tree built after it by a layout swap takes over the window's route;
    /// the same tree appearing again (a tab switch) changes nothing once the
    /// window has landed. A wide tree hosts the feed reader too.
    func mailTreeAppeared(_ tree: UUID, isWide: Bool) async {
        let isRebuild = mailTrees.appear(tree)
        layoutIsWide = isWide
        if isWide {
            hasShownMail = true
            feedTreeArrived(tree, showsReader: route.section == .feeds)
        }
        guard isRebuild, didLand else {
            mailTrees.mount(tree)
            await landIfNeeded(tree, isWide: isWide)
            return
        }
        await rehand(tree, isWide: isWide)
        // A tree that a second swap replaced while this one waited on the
        // feed store takes nothing over.
        guard isCurrent(tree, isWide: isWide) else { return }
        mailTrees.mount(tree)
    }

    /// A rebuilt tree renders the route: the folder stays, an open message is
    /// parked for the new list to select after its initial load — before the
    /// tree sees the folder, so the list mounts with the restore waiting —
    /// and the compact column starts on that folder's list. Where the window
    /// has no mail folder open, the tree lands on the folder its stored route
    /// names when the window never opened it, else, where the user backed
    /// out to the folder list or the wide layout cleared it for a feed, on
    /// the live session, as every rebuilt tree used to. A wide tree in the feeds section shows
    /// the window's feed list; a window that never landed in feeds reopens
    /// its stored scope, else the session's; with neither, the split shows
    /// mail.
    private func rehand(_ tree: UUID, isWide: Bool) async {
        listHold.handOff(isWide: isWide, folderPath: selectedFolder?.path, parkingIn: restores)
        selectedEnvelope = nil
        compactColumn = CompactColumnPolicy.afterFolderChange(hasFolder: selectedFolder != nil)
        guard let coordinator = coordinator() else { return }
        if isWide, route.section == .feeds {
            if feeds.scope != nil {
                // The split shows the window's feed list, so the mail side
                // clears, as for a feed pick.
                enterFeeds()
                return
            }
            if !feeds.didLand, await landsInFeeds(tree, coordinator) { return }
            // No list to show, so the split shows mail: the section moves,
            // as the landing's folder record used to move it.
            moveSection(to: .mail)
            recorder.section(.mail)
        }
        if selectedFolder == nil {
            // Where the user is now, not where the process started (#1555),
            // unless the window's own stored folder was never opened.
            coordinator.didConsumeLaunchSession = true
            if hasClient() { landOnSessionFolder(coordinator, stored: route.mail) }
        } else if let message = route.mail.message, !restores.hasPendingRestore(in: message.folder) {
            // Unless a restore for the folder is already waiting: a
            // navigation or a landing the list has not applied yet, newer
            // than the open message and carrying any reading position with
            // it, which a bare re-park would replace.
            restores.schedule(coordinator.restoreCursor(for: message), priming: recorder.recording)
        }
    }

    /// Whether `tree` is still the one taking the window over, in the layout
    /// it appeared in: a second swap during a feed-store wait may have built
    /// another tree, or gone back to a compact tab that has no mail tree.
    private func isCurrent(_ tree: UUID, isWide: Bool) -> Bool {
        mailTrees.isAppearing(tree) && layoutIsWide == isWide
    }

    // MARK: Landing

    /// The launch landing (`docs/1.x/resume-session-plan.md`). A deep link
    /// parked before this window existed (a cold launch from a tap), or one
    /// it is still looking up, is the landing, and pre-empts the session's.
    /// Otherwise the window's stored route (`StoredRoute`) comes before the
    /// session: a route or session that ended in the feed reader reopens its
    /// scope on the wide layout, which hosts feeds in the same split;
    /// anything else lands provisionally on that folder (INBOX when there is
    /// none) right away, before `/list_folders` returns, so the message list and
    /// its envelope cache start loading, with the open message scheduled for
    /// the list to reselect. The folder list's first load swaps the fetched
    /// folder in (`foldersLoaded`). Seeded as subscribed so the list doesn't
    /// flash the unsubscribed-folder banner before the real state arrives.
    private func landIfNeeded(_ tree: UUID, isWide: Bool) async {
        guard let coordinator = coordinator() else { return }
        if let link = deepLinks.takeParked() { await open(link, coordinator, ifStill: deepLinks.generation) }
        await opening?.value
        guard !didLand, selectedFolder == nil else { return }
        if isWide, splitShowsFeeds {
            // The Feeds tab landed before the window widened: the window has
            // landed, in the feed reader, and the folder list's first load
            // must not land mail behind it.
            didLand = true
            return
        }
        guard hasClient() else { return }
        didLand = true
        if isWide, route.section == .feeds, !feeds.didLand, await landsInFeeds(tree, coordinator) {
            return
        }
        landOnSessionFolder(coordinator, stored: route.mail)
    }

    /// The provisional mail landing: the window's stored folder (`stored`)
    /// or the session's (the launch snapshot for a window's first landing,
    /// the live session after it), its open message scheduled for the list,
    /// and the folder list's first load to reconcile it.
    private func landOnSessionFolder(_ coordinator: NavStateCoordinator, stored: AppRoute.Mail = AppRoute.Mail()) {
        let target = coordinator.mailLaunchTarget(stored: stored)
        awaitingLaunchReconcile = true
        recorder.recording?.armProvisionalLanding()
        restores.park(target, priming: recorder.recording)
        setFolder(Folder(path: target.folderPath, isSubscribed: true), records: hasShownMail)
    }

    /// The folder list's first load. Finishes a provisional landing, or a
    /// launch whose client was not wired in time to land at all; otherwise
    /// swaps the fetched folder in for a same-path stand-in a navigate
    /// request selected before the list arrived (#1535).
    func foldersLoaded(_ folders: [Folder]) {
        loadedFolders = folders
        if awaitingLaunchReconcile, selectedFolder == nil {
            // The user left the provisional landing before the list arrived
            // (on iPhone, back to the folder list): finish the launch without
            // landing them again (#1912).
            awaitingLaunchReconcile = false
            coordinator()?.materializeLanding()
        } else if awaitingLaunchReconcile || (!didLand && selectedFolder == nil) {
            awaitingLaunchReconcile = false
            finishLaunchLanding(from: folders)
        } else if let current = selectedFolder,
                  let fetched = folders.first(where: { $0.path == current.path }), fetched != current {
            setFolder(fetched)
        }
    }

    /// Completes the launch landing once the folder list arrives. The
    /// fetched folder of the provisional landing's path is swapped in — same
    /// path, so the mounted list survives and nothing is re-recorded. A
    /// folder that no longer exists (deleted since the session was saved,
    /// perhaps from another device) falls back to INBOX and drops the message
    /// restore aimed at it. The landing's own server write, held back so the
    /// cross-device probe reads another install's cursor
    /// (`armProvisionalLanding`), goes out once the probe has run
    /// (`materializeLanding`).
    private func finishLaunchLanding(from folders: [Folder]) {
        let inbox = folders.first { folder in
            folder.path.caseInsensitiveCompare("INBOX") == .orderedSame
        } ?? folders.first
        let coordinator = coordinator()
        didLand = true
        if let current = selectedFolder {
            if let fetched = folders.first(where: { $0.path == current.path }) {
                setFolder(fetched)
            } else if let inbox {
                restores.clearPendingRestore()
                setFolder(inbox, records: hasShownMail)
            }
        } else if let coordinator {
            // The client wasn't wired when the tree appeared, so there was no
            // provisional landing: land now. A folder that is gone falls back
            // to INBOX without its message.
            let target = coordinator.mailLaunchTarget(stored: route.mail)
            recorder.recording?.armProvisionalLanding()
            let landing = folders.first { $0.path == target.folderPath }
            if landing != nil { restores.park(target, priming: recorder.recording) }
            setFolder(landing ?? inbox)
        } else {
            setFolder(inbox)
        }
        coordinator?.materializeLanding()
    }

    /// The fetched `Folder` for `path` when the sidebar has loaded it, else a
    /// stand-in that the next `foldersLoaded` swaps out (#1535).
    func resolvedFolder(path: String) -> Folder {
        loadedFolders.first { $0.path == path } ?? Folder(path: path)
    }

    // MARK: Navigation

    /// Takes a cursor to this window — a tapped notification, a Spotlight
    /// result, Siri, the resume banner: parks its message for this window's
    /// list and moves to its folder and the Mail tab. A new folder re-mounts
    /// the list, which takes the restore; a mounted list sees the new one.
    /// Supersedes a link parked for a first landing and a parked list place.
    /// A window opened after it lands where the user went (#1966).
    func navigate(to cursor: NavState) {
        guard let coordinator = coordinator() else { return }
        deepLinks.discardParked()
        coordinator.endLaunchSnapshot()
        restores.dropListAnchor()
        restores.schedule(cursor, priming: recorder.recording)
        if selectedFolder?.path != cursor.folder {
            setFolder(resolvedFolder(path: cursor.folder))
        }
        didLand = true
        // The compact tab bar opens on Mail, noting the section as a tab
        // switch does; the wide layout's folder record moves the session.
        if layoutIsWide { compactTab = .mail } else { showTab(.mail) }
    }

    /// A sidebar pick, or the list's folder-switch menu. A pick of the folder
    /// already selected still comes through here, which is what lets the
    /// view end a search on it (#1217). On the wide split, a folder picked
    /// while it shows feeds closes the feed list, and that is recorded.
    func selectFolder(_ folder: Folder?) {
        if folder != nil, layoutIsWide, splitShowsFeeds { record(feeds.selectScope(nil)) }
        setFolder(folder)
        if folder != nil { followSplit() }
    }

    /// The list's selection from `tree` — a tap, a restore, an advance after
    /// a dispose.
    func selectMessage(_ envelope: Envelope?, isSearching: Bool, from tree: UUID) {
        guard canWrite(from: tree) else { return }
        let before = route
        applyMessage(envelope, isSearching: isSearching)
        if route != before { followSplit() }
    }

    /// The collapsed split view moved column from `tree` (the back gesture).
    /// Leaving the reader drops the open message, so the same row can be
    /// opened again.
    func setCompactColumn(_ column: NavigationSplitViewColumn, isSearching: Bool, from tree: UUID) {
        guard canWrite(from: tree), column != compactColumn else { return }
        compactColumn = column
        // Back to the folder list: the message list is gone, with its selection.
        if column == .sidebar { listHold.backOut(from: restores) }
        if CompactColumnPolicy.dropsMessage(movingTo: column) {
            applyMessage(nil, isSearching: isSearching)
        }
    }

    /// The compact tab bar switched, or a navigation moved it. The Mail and
    /// Feeds tabs each keep their own position, so only the section moves;
    /// the utility tabs move nothing, and re-selecting the tab on screen
    /// notes nothing.
    func showTab(_ tab: CompactTab) {
        guard tab != compactTab else { return }
        compactTab = tab
        guard let section = tab.resumeSection else { return }
        if section == .mail { hasShownMail = true }
        route.section = section
        recorder.section(section)
    }

    // MARK: Transitions

    private func canWrite(from tree: UUID) -> Bool {
        mailTrees.canWrite(tree)
    }

    /// The wide split switching to feeds: the mail folder and message clear.
    /// Neither is recorded; the feed scope's own record moves the session.
    private func enterFeeds() {
        setFolder(nil)
        applyMessage(nil, isSearching: false)
        moveSection(to: .feeds)
    }

    /// - Parameter records: whether a new folder moves the session there.
    ///   Only a landing before the window has shown mail passes false.
    private func setFolder(_ folder: Folder?, records: Bool = true) {
        // A same-path write is a metadata reconcile — the provisional
        // `Folder(path:)` swapped for the fetched one: same mailbox, so the
        // message stays and nothing is re-recorded.
        guard folder?.path != selectedFolder?.path else {
            if folder != selectedFolder { selectedFolder = folder }
            return
        }
        selectedFolder = folder
        selectedEnvelope = nil
        listHold.drop(from: restores, landingOn: folder?.path)
        route.mail = AppRoute.Mail(folderPath: folder?.path)
        compactColumn = CompactColumnPolicy.afterFolderChange(hasFolder: folder != nil)
        guard let path = folder?.path, records else { return }
        moveSection(to: .mail)
        // Folder is the cursor's highest-priority field; the coordinator
        // debounces and de-dupes the write.
        recorder.folder(path)
        // visionOS's Folders tab picks the folder for its Mail tab, so a new
        // folder chosen there shows its messages.
        if compactTab == .folders { showTab(.mail) }
    }

    private func applyMessage(_ envelope: Envelope?, isSearching: Bool) {
        guard envelope != selectedEnvelope else { return }
        selectedEnvelope = envelope
        compactColumn = CompactColumnPolicy.column(hasSelectedMessage: envelope != nil, current: compactColumn)
        // While searching, the open message is a result with no single folder
        // to anchor the cursor to.
        guard !isSearching, let folderPath = selectedFolder?.path else { return }
        guard let envelope else {
            route.mail.message = nil
            recorder.noMessage(folderPath: folderPath)
            return
        }
        // Anchored to the sidebar's folder: a row from another folder is not
        // this folder's position.
        let ref = envelope.ref(defaultFolder: folderPath)
        guard ref.folder == folderPath else { return }
        route.mail.message = ref
        recorder.message(ref)
    }

    /// A landing moved the window to `section`. The wide layout has no tab
    /// bar; its tab is the one a swap to the compact layout opens on, so a
    /// Mail or Feeds tab follows a change of section. A utility tab stays:
    /// only a pick in the split moves it (`followSplit`).
    private func moveSection(to section: ResumeSession.Section) {
        guard route.section != section else { return }
        route.section = section
        if layoutIsWide, compactTab.resumeSection != nil { compactTab = CompactTab.initial(for: section) }
    }

    /// The user acted in the wide split — a folder or feed pick, a different
    /// message — so a swap to the compact layout opens on that section. A
    /// rebuilt tree restoring what the window had is not an action, so a
    /// utility tab survives a round trip with nothing picked.
    private func followSplit() {
        if layoutIsWide { compactTab = CompactTab.initial(for: route.section) }
    }
}

// The feed reader's half, in the same file so it reaches the window's private
// state and keeps the class body under the type-length cap.
extension SceneNavigator {
    /// Whether the wide split shows the feed reader rather than mail: the
    /// window is in the feeds section with a list open.
    var splitShowsFeeds: Bool {
        route.section == .feeds && feeds.scope != nil
    }

    /// A `FeedRootView` appeared. The window's first feed tree lands — the
    /// session's scope, its open item parked for the list (the launch
    /// snapshot on the window's first landing, the live session after it);
    /// one a layout swap built takes the reader over (`feedTreeArrived`).
    func feedTreeAppeared(_ tree: UUID) async {
        feedTreeArrived(tree, showsReader: true)
        guard !feeds.didLand, feeds.scope == nil, let coordinator = coordinator() else { return }
        let target = await feedsLaunchTarget(coordinator, route.feeds)
        // A tree a swap replaced during the lookup lands nothing; one that
        // took over meanwhile may have landed already.
        guard feeds.isAppearing(tree), !feeds.didLand else { return }
        feeds.markLanded()
        if let target { record(feeds.selectScope(restores.park(target))) }
    }

    /// A feed pick on the wide layout, where feeds and mail share one split:
    /// the mail folder and message clear. A scope held while the split showed
    /// mail (the compact Feeds tab's place) opens afresh.
    func showFeeds(_ scope: RssItemScope?) {
        let wasShowing = splitShowsFeeds
        guard scope != nil || wasShowing else { return }
        if scope != nil {
            enterFeeds()
            followSplit()
        }
        record(wasShowing ? feeds.selectScope(scope) : feeds.openScope(scope))
    }

    /// A scope picked in the Feeds tab's sidebar or its list's switcher.
    func selectFeedScope(_ scope: RssItemScope?) {
        record(feeds.selectScope(scope))
    }

    /// The feed list's selection from `tree`: a tap, or the parked item it
    /// applied once loaded. A different item in the wide split moves the
    /// compact tab, as a message does.
    func selectFeedItem(_ item: RssItem?, from tree: UUID) {
        let before = route
        record(feeds.selectItem(item, from: tree))
        if route != before { followSplit() }
    }

    /// The collapsed Feeds split moved column from `tree` (the back gesture).
    func setFeedColumn(_ column: NavigationSplitViewColumn, from tree: UUID) {
        record(feeds.setColumn(column, from: tree))
    }

    /// A tapped feed banner (`NavStateCoordinator.requestFeedNavigation`):
    /// this window opens the item's scope and parks the item, which the list
    /// selects once it has appeared and loaded, or at once if it is on screen.
    func navigateFeeds(to target: NavStateCoordinator.FeedLaunchTarget) {
        let scope = restores.park(target)
        feeds.markLanded()
        feedNavigations += 1
        if layoutIsWide {
            showFeeds(scope)
        } else {
            showTab(.feeds)
            record(feeds.selectScope(scope))
        }
    }

    /// The wide split's landing in feeds: the session's scope, when it is
    /// still in the store, clearing the mail side as a feed pick does.
    /// Returns whether that settled the tree: it opened the scope, or a swap
    /// replaced it during the lookup and the tree that takes over lands
    /// instead. False sends it on to mail.
    private func landsInFeeds(_ tree: UUID, _ coordinator: NavStateCoordinator) async -> Bool {
        let target = await feedsLaunchTarget(coordinator, route.feeds)
        guard isCurrent(tree, isWide: true) else { return true }
        feeds.markLanded()
        guard let target else { return false }
        enterFeeds()
        record(feeds.openScope(restores.park(target)))
        return true
    }

    /// A tree that hosts feeds appeared: `FeedRootView`, or a wide
    /// `MailRootView`. One a layout swap built takes the reader over. When it
    /// shows the reader, the open item is parked for its list to select once
    /// it has appeared and loaded (#1664), unless the list already waits on
    /// one (a banner's); a wide split showing mail keeps it for the Feeds tab.
    private func feedTreeArrived(_ tree: UUID, showsReader: Bool) {
        if feeds.appear(tree), showsReader, let scope = feeds.scope,
           let item = feeds.takeItemForHandOff(), restores.pendingFeedRestore?.scope != scope {
            restores.parkFeedItem(item, in: scope)
        }
        feeds.mount(tree)
    }

    /// Records a feed transition on the resume session and the route.
    private func record(_ records: [FeedNavigationState.Record]) {
        for record in records {
            switch record {
            case .scope(let scope):
                route.feeds = AppRoute.Feeds(scope: scope)
                recorder.feedScope(scope)
                // An item parked for another list is stale now: the list
                // would otherwise open it the next time it comes back.
                if let parked = restores.pendingFeedRestore?.scope, parked != scope {
                    _ = restores.consumeFeedItemRestore(for: parked)
                }
            case .item(let item):
                route.feeds.item = item.map(AppRoute.Item.init)
                recorder.feedItem(item)
                // Picked before the list applied the item parked for it:
                // the pick wins, and a later hand-off parks the pick.
                if item != nil, let scope = feeds.scope {
                    _ = restores.consumeFeedItemRestore(for: scope)
                }
            }
        }
    }
}

// Deep links (`DeepLinkRouter`), in the same file so they reach the session's
// coordinator.
extension SceneNavigator {
    /// A deep link the router delivered to this window. A notification's or
    /// Siri's opens at once; a Spotlight result once its Message-ID is
    /// looked up. With no session to open it in, it goes back to the router.
    func open(_ link: DeepLink) {
        guard let coordinator = coordinator() else { return deepLinks.giveBack(link) }
        if let cursor = coordinator.immediateCursor(for: link) { return navigate(to: cursor) }
        let generation = deepLinks.generation
        opening = Task { await open(link, coordinator, ifStill: generation) }
    }

    /// Opens `link` once its cursor is known, unless a later link or a
    /// navigation has come since `generation` (`DeepLinkRouter.generation`).
    private func open(_ link: DeepLink, _ coordinator: NavStateCoordinator, ifStill generation: Int) async {
        let cursor = await coordinator.cursor(for: link)
        guard deepLinks.generation == generation else { return }
        navigate(to: cursor)
    }
}

// The window's search, in the same file so it reaches the stored model.
extension SceneNavigator {
    /// The window's search model, created on first use for `client`. One per
    /// window, so each window keeps its own query and results; shared by the
    /// window's layout trees (the regular split's search field and the
    /// compact Search tab), so a layout swap keeps them (#1654). A new
    /// sign-in gets a new navigator, and the model goes with the old one.
    func searchModel(
        client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore
    ) -> MessageListViewModel {
        if let search, search.client === client { return search }
        let model = MessageListViewModel(
            scope: .search, client: client, preferences: preferences, mailStore: mailStore
        )
        search = model
        return model
    }
}

// The message list's selection, kept with the list's place.
extension SceneNavigator {
    /// The selection for a folder list mounting here (`FolderListHold`).
    func mailSelection(for folderPath: String) -> SelectionModel<MessageRef> {
        listHold.mailSelection(for: folderPath)
    }
}

// Applies `ShellHandOff`'s decisions, which take the tab and the window's search.
extension SceneNavigator {
    /// Whether the split shows its Settings sheet.
    var showsSettingsSheet: Bool { layoutIsWide && shellHandOff.settingsSheetOpen }

    /// A Settings request in the split.
    func openSettingsSheet() { shellHandOff.openSettingsSheet() }

    /// The layout shell changed: the host's own old and new, since a tree's landing also writes `layoutIsWide`.
    func layoutChanged(wasWide: Bool, isWide: Bool) {
        layoutIsWide = isWide
        let engaged = search.map { !$0.searchQuery.isEmpty || $0.isSearchActive } ?? false
        switch shellHandOff.layoutChanged(wasWide: wasWide, isWide: isWide, tab: compactTab, searchIsEngaged: engaged) {
        case .nothing: break
        case .showTab(let tab): showTab(tab)
        case .endLeftoverSearch:
            // Now, not in a task: the split's landing takes the model next.
            search?.filterTab = .all
            search?.search.clear()
        }
    }

    /// The split's Settings sheet was dismissed.
    func settingsSheetDismissed() {
        guard shellHandOff.sheetDismissed(isShowing: showsSettingsSheet, tab: compactTab) else { return }
        compactTab = CompactTab.initial(for: route.section)
    }
}
