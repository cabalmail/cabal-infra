#if os(visionOS)
import SwiftUI
import CabalmailKit

/// visionOS section navigation: a floating leading tab bar.
///
/// On visionOS a `TabView` is presented as an ornament docked to the window's
/// leading edge — the spatial idiom for top-level navigation. Each tab is a
/// destination:
///
/// - **Mail** — the message list + reader for the selected folder. There is no
///   folder sidebar here; the Folders tab is how the mailbox in view changes.
/// - **Folders** — the folder list. Picking a folder drives the Mail tab's
///   message list and switches back to Mail so the messages are front-and-center.
/// - **Addresses** — the shared `AddressListView` (request / revoke / favorite).
/// - **Settings** — general preferences.
/// - **Search** — cross-folder search.
///
/// This replaces the earlier visionOS path, which reused the iPad
/// `MailRootView`: its folders lived in a show/hide `NavigationSplitView`
/// sidebar whose reveal toggle visionOS never surfaced, leaving no discoverable
/// way to reach the folder list.
struct VisionSectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    /// Mailbox selection shared across tabs: the Folders tab writes it, the Mail
    /// tab reads it. Lifted here (rather than owned by either tab) so a folder
    /// pick reconfigures the message list even though the two live in different
    /// tabs.
    @State private var selectedFolder: Folder?
    /// The visible tab. Bound so a Folders pick, the ⌘, command, and a resume
    /// tap can switch tabs programmatically. Seeded from the stored resume
    /// session so a launch that ended in the feed reader opens on Feeds (a
    /// `@State` default can't reach the environment, hence the direct store
    /// read).
    @State private var selection: Section = ResumeSessionStore.storedSection() == .feeds ? .feeds : .mail
    /// True once the launch INBOX landing has run, so nothing re-seeds the
    /// selection out from under the user later.
    @State private var didLand = false

    enum Section: Hashable { case mail, folders, feeds, addresses, settings, search }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Mail", systemImage: "tray", value: Section.mail) {
                VisionMailPane(selectedFolder: $selectedFolder)
            }
            Tab("Folders", systemImage: "folder", value: Section.folders) {
                foldersTab
            }
            Tab("Feeds", systemImage: "dot.radiowaves.up.forward", value: Section.feeds) {
                FeedRootView()
            }
            Tab("Addresses", systemImage: "at", value: Section.addresses) {
                AddressManagementTab()
            }
            Tab("Settings", systemImage: "gear", value: Section.settings) {
                SettingsView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: Section.search) {
                SearchView()
            }
        }
        // Land on INBOX at launch regardless of which tab (Mail) is showing, so
        // the message list isn't empty before the user ever visits Folders. The
        // Folders tab's own list loads lazily on first appearance, so the seed
        // has to come from here.
        .task { await landOnInboxIfNeeded() }
        // A folder pick in the Folders tab jumps to Mail. Guarded on the current
        // tab so the launch / resume folder changes (which target Mail
        // themselves) don't trigger a redundant switch, and on the path so the
        // launch landing's same-folder metadata reconcile (see
        // `landOnInboxIfNeeded`) doesn't yank the user out of Folders.
        .onChange(of: selectedFolder) { old, folder in
            if folder != nil, old?.path != folder?.path, selection == .folders { selection = .mail }
        }
        // ⌘, opens Settings — its own tab here, rather than the iPad sheet.
        .onChange(of: appState.settingsRequestTick) { _, _ in
            selection = .settings
        }
        // The resume session remembers which section the user was in; Mail
        // and Feeds each keep their own position, so only the section moves.
        .onChange(of: selection) { _, tab in
            switch tab {
            case .mail, .folders: appState.navCoordinator?.noteSection(.mail)
            case .feeds: appState.navCoordinator?.noteSection(.feeds)
            case .addresses, .settings, .search: break
            }
        }
        // Foreground reconcile: if another client moved the cursor on, offer the
        // jump. Mirrors `MailRootView`'s handler; `hasLoadedInitial` gates out
        // the cold-launch path (which offers its own resume toast from
        // `landOnInboxIfNeeded`).
        .onChange(of: scenePhase) { old, new in
            guard new == .active, old != .active,
                  let coordinator = appState.navCoordinator,
                  coordinator.hasLoadedInitial else { return }
            Task {
                if let cursor = await coordinator.foreignCursorOnForeground() {
                    appState.showToast(
                        .resumeNavigation(folderName: Folder(path: cursor.folder).name, cursor: cursor),
                        duration: 10
                    )
                }
            }
        }
        // A resume toast was tapped: jump to the cursor's folder in Mail.
        .onChange(of: appState.navCoordinator?.navigateRequest) { _, request in
            guard let request, let coordinator = appState.navCoordinator else { return }
            coordinator.navigateRequest = nil
            coordinator.scheduleRestore(for: request)
            selection = .mail
            if selectedFolder?.path != request.folder {
                selectedFolder = Folder(path: request.folder)
            }
        }
    }

    /// Folders tab: the shared `FolderListView` bound to the cross-tab
    /// selection. No `onFoldersLoaded` seed here — the launch landing comes from
    /// `landOnInboxIfNeeded` (which runs even while this tab is unmounted), so
    /// this tab only ever changes `selectedFolder` on a real user pick.
    @ViewBuilder
    private var foldersTab: some View {
        NavigationStack {
            FolderListView(selection: $selectedFolder, externalFilter: nil)
        }
    }

    /// Lands the Mail tab at launch on the resume session's folder (INBOX
    /// when there is none), reselecting its open message, and offers the
    /// cross-device toast if another install's cursor is reachable. Mirrors
    /// `MailRootView`'s provisional landing: a synthetic `Folder(path:)` is
    /// selected immediately so the message list starts loading without
    /// waiting on `/list_folders` (the message machinery only needs the
    /// path; seeded as subscribed so the list doesn't flash the
    /// unsubscribed-folder banner). The fetched folder is swapped in once the
    /// list arrives — sourced from its own `FolderListViewModel` because
    /// there's no always-mounted sidebar to hand one over — or INBOX if the
    /// folder no longer exists. The Feeds tab restores its own position
    /// (`FeedRootView`).
    private func landOnInboxIfNeeded() async {
        guard !didLand, selectedFolder == nil, let client = appState.client else { return }
        didLand = true
        let coordinator = appState.navCoordinator
        let target = coordinator?.mailLaunchTarget()
            ?? NavStateCoordinator.MailLaunchTarget(folderPath: "INBOX", messageRestore: nil)
        coordinator?.armProvisionalLanding()
        if let restore = target.messageRestore {
            coordinator?.scheduleRestore(for: restore)
        }
        selectedFolder = Folder(path: target.folderPath, isSubscribed: true)
        let model = FolderListViewModel(client: client, appState: appState)
        await model.loadFolderList()
        let folders = model.folders
        guard !folders.isEmpty else { return }
        let inbox = folders.first { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame } ?? folders.first
        // Swap the fetched folder into the provisional selection so the
        // Folders tab's row highlight matches (`Folder` equality spans
        // attributes / subscription). Same path — the mounted message list
        // survives, and `VisionMailPane`'s same-path guard keeps the swap
        // from clearing the open message. Skipped if the user already
        // navigated elsewhere; a folder that no longer exists falls back to
        // INBOX and drops the message restore aimed at it.
        if let current = selectedFolder, current.path == target.folderPath {
            if let fetched = folders.first(where: { $0.path == current.path }) {
                selectedFolder = fetched
            } else if let inbox {
                coordinator?.clearPendingRestore()
                selectedFolder = inbox
            }
        }
        let landedPath = selectedFolder?.path
        let candidate = await coordinator?.launchResumeCandidate(folders: folders)
        // If the user already navigated elsewhere while the probe ran, leave
        // them be rather than surfacing a now-stale prompt.
        guard let landedPath, selectedFolder?.path == landedPath else { return }
        if let candidate {
            appState.showToast(
                .resumeNavigation(folderName: Folder(path: candidate.folder).name, cursor: candidate),
                duration: 10
            )
        } else {
            coordinator?.materializeLanding()
        }
    }
}

/// Mail tab body: a two-column list + reader for the selected folder, with no
/// folder sidebar (folders are their own tab). Selection is local; the folder
/// comes in from `VisionSectionView`. Records the cross-client cursor as the
/// user moves through folders and messages, matching `MailRootView`.
private struct VisionMailPane: View {
    @Binding var selectedFolder: Folder?
    @Environment(AppState.self) private var appState
    @State private var selectedEnvelope: Envelope?
    /// How many messages the list currently has selected. Drives the "N
    /// messages selected" reading-pane placeholder during a multi-selection.
    @State private var listSelectionCount = 0

    var body: some View {
        NavigationSplitView {
            listColumn
        } detail: {
            detailColumn
        }
        // Switching folders clears the open message and any multi-selection so
        // the reader can't briefly show an old message against the new mailbox,
        // then records the folder move for the cross-client cursor. A same-path
        // change is the launch landing's metadata reconcile — same mailbox, so
        // keep the open message and don't re-record the cursor.
        .onChange(of: selectedFolder) { old, folder in
            guard old?.path != folder?.path else { return }
            selectedEnvelope = nil
            listSelectionCount = 0
            if let path = folder?.path {
                appState.navCoordinator?.recordFolder(path)
            }
        }
        // Record the open message (or its absence) for the cursor.
        .onChange(of: selectedEnvelope) { _, envelope in
            guard let folderPath = selectedFolder?.path else { return }
            if let envelope {
                appState.navCoordinator?.recordMessage(
                    folderPath: folderPath,
                    uid: envelope.uid,
                    messageID: envelope.messageId
                )
            } else {
                appState.navCoordinator?.recordNoMessage(folderPath: folderPath)
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        if let selectedFolder {
            MessageListView(
                scope: .folder(selectedFolder),
                selection: $selectedEnvelope,
                onSearchResultSelected: { _ in },
                onSelectionCountChanged: { listSelectionCount = $0 },
                // The list's folder-switch menu writes the cross-tab
                // selection exactly as a Folders-tab pick does. `self.`
                // because the enclosing `if let` shadows the binding with
                // the unwrapped constant.
                onSwitchFolder: { self.selectedFolder = $0 }
            )
            .id(selectedFolder.path)
        } else {
            ContentUnavailableView(
                "Select a folder",
                systemImage: "folder",
                description: Text("Pick a folder from the Folders tab to browse messages.")
            )
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if listSelectionCount >= 2 {
            ContentUnavailableView(
                "\(listSelectionCount) Messages Selected",
                systemImage: "envelope.badge",
                description: Text("Use the action bar below the list to act on them together.")
            )
        } else if let folder = selectedFolder, let selectedEnvelope {
            MessageDetailView(folder: folder, envelope: selectedEnvelope)
                .id("\(folder.path)#\(selectedEnvelope.uid)")
        } else {
            ContentUnavailableView(
                "No message selected",
                systemImage: "envelope",
                description: Text("Pick a message from the list to read it.")
            )
        }
    }
}
#endif
