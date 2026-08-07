import SwiftUI
import CabalmailKit

/// Message detail pane — headers block, body renderer, attachment strip.
///
/// Body rendering prefers HTML when both alternatives are present (matches
/// the React app). Remote content is gated off by default per the plan's
/// Phase 4 preference; the toolbar button toggles the reload.
///
/// Layout: the header block and attachment strip sit in a fixed-height
/// region at the top; the body fills the remaining height of the detail
/// column with its own scroll. Previously we wrapped everything in a single
/// outer `ScrollView`, which forced the `WKWebView` onto a fixed `minHeight`
/// (the web view has no intrinsic content size for SwiftUI to grow into),
/// so resizing the window had no effect on the reading area.
struct MessageDetailView: View {
    let folder: Folder
    let envelope: Envelope

    // Properties reached by sibling extensions in `+Toolbar` and `+Compose`
    // are kept at internal (default) access. `private` in this struct
    // would block access from those files even though they're in the same
    // module; the same-module / different-file extension pattern is the
    // accepted way to keep this struct under SwiftLint's body-length cap.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) var preferences
    @State var model: MessageDetailViewModel?
    @State var moveSheetPresented = false
    @State var sourceSheetTab: MessageSourceSheet.Tab?
    @State var senderContactName: String?
    /// Presents the "Delete Forever?" confirmation when the delete button
    /// fires while the message lives in Trash. Non-private so the
    /// `+Toolbar` extension's dispose button can stage it.
    @State var purgeConfirmPresented = false
    // Header address-menu state, populated by `loadAddressMenuContext()` and
    // read by the `+AddressMenu` extension to gate the Contacts and "Compose
    // From" items.
    @State var contactsAuth: ContactsAuthorizationStatus = .notDetermined
    // The user's own addresses, kept as full `Address` values (not just the
    // string) so the menu's "Revoke" item has the subdomain / tld / public key
    // the `/revoke` API needs.
    @State var ownedAddresses: [Address] = []
    // Address staged for revocation by the header menu's "Revoke" item,
    // confirmed before the (irreversible) API call.
    @State var pendingRevoke: Address?
    #if os(iOS) || os(visionOS)
    @State var contactEditorRequest: ContactEditorRequest?
    #endif
    // In-message scroll restore/capture. Consumed once from the nav cursor
    // after the body loads: `restoreScrollAnchor` feeds the HTML web view,
    // `restoreScrollOffset` positions the plain-text scroll view. The reader
    // reports the live position back so it survives across launches/devices.
    // Helpers live in `MessageDetailView+Scroll.swift`; see there.
    @State var restoreScrollAnchor: String?
    @State var restoreScrollOffset: Int?
    @State var didConsumeScrollRestore = false
    @State var plainScrollPosition = ScrollPosition(edge: .top)
    // `nil` until the first scroll report — a sentinel `Int.min` would overflow
    // the `offset - lastReportedPlainOffset` delta on the first callback.
    @State var lastReportedPlainOffset: Int?
    // Measured height of `headerBlock`, so the header sizes to its content
    // instead of to a fixed slice of the pane. See
    // `ReaderHeaderHeightPolicy`.
    @State var headerContentHeight: CGFloat = 0
    #if os(iOS)
    // Drives `drawsOwnActionBar`: at regular width the reader shares the
    // window with the message list, and on iOS 27 a `.bottomBar` group
    // spreads across both columns. See `ReaderToolbarLayout`.
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif

    /// True when the reader pins the action set under its own pane instead of
    /// emitting a `.bottomBar` toolbar group. iOS 27 at regular width only —
    /// every other platform and OS generation keeps the system bar.
    var drawsOwnActionBar: Bool {
        #if os(iOS)
        // A runtime check, not a compile-time one: CI builds this with the
        // stable Xcode against the iOS 26 SDK, and the same binary has to
        // pick the right bar on both OS generations.
        let isOS27OrLater: Bool
        if #available(iOS 27.0, *) { isOS27OrLater = true } else { isOS27OrLater = false }
        return ReaderToolbarLayout.usesOwnActionBar(
            isRegularWidth: horizontalSizeClass == .regular,
            isOS27OrLater: isOS27OrLater
        )
        #else
        return false
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                // Subject is shown in full in the pane (the list truncates
                // it) and the header is allowed to grow with a wrapping
                // subject. The block takes the height its content actually
                // needs, and only scrolls once that would claim more of the
                // pane than `ReaderHeaderHeightPolicy` allows. A ScrollView
                // is greedy along its scroll axis, so this has to be an
                // explicit height rather than a `maxHeight` — a cap alone
                // makes the block exactly that tall whatever it holds, which
                // is what pushed the authentication line out of view.
                ScrollView(.vertical) {
                    headerBlock
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .onGeometryChange(for: CGFloat.self) { headerProxy in
                            headerProxy.size.height
                        } action: { newHeight in
                            headerContentHeight = newHeight
                        }
                }
                .frame(height: ReaderHeaderHeightPolicy.height(
                    contentHeight: headerContentHeight,
                    paneHeight: proxy.size.height
                ))
                if let attachments = model?.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                        .padding(.vertical, 8)
                }
                Divider()
                if let model {
                    body(for: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        #if os(macOS)
        // macOS renders the subject in the window's title bar (its own chrome),
        // separate from the reading area, so it doesn't duplicate the header
        // block. iPad/iPhone suppress the inline title (see #else) because there
        // it sat right above the header's copy of the subject.
        .navigationTitle(envelope.subject ?? "(no subject)")
        #else
        // Suppress the inline nav-bar subject: it duplicated the subject shown
        // in `headerBlock` right below it, and blanking it reclaims the detail
        // column's top bar for the global search field that `MailRootView` hosts
        // there on wide (iPad-regular) layouts.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Reading a message uses the full bottom edge for the action toolbar;
        // the compact-width section `TabView`'s bottom tab bar would otherwise
        // occlude it. The tab bar reappears automatically when the user swipes
        // back to the message list. At regular width (iPad / visionOS) there's
        // no section tab bar - those sections live in the Settings sheet now -
        // so this is a no-op there.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar { toolbarContent }
        #if os(iOS)
        // Pins the action set to the reading pane on iOS 27 at regular width.
        // Inert (empty content) everywhere else, so compact iPhone and iOS 26
        // keep the system `.bottomBar` group untouched.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if drawsOwnActionBar { readerActionBar }
        }
        #endif
        .sheet(isPresented: $moveSheetPresented) {
            moveSheet
        }
        .sheet(item: $sourceSheetTab) { tab in
            sourceSheet(initialTab: tab)
        }
        #if os(iOS) || os(visionOS)
        .sheet(item: $contactEditorRequest) { request in
            ContactEditorView(request: request) { contactEditorRequest = nil }
        }
        #endif
        .task { await loadAddressMenuContext() }
        .confirmationDialog(
            "Delete Forever?",
            isPresented: $purgeConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                runPurge()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message will be permanently deleted. This can't be undone.")
        }
        .modifier(RevokeAddressConfirmation(pending: $pendingRevoke, perform: revoke))
        .onChange(of: appState.replyRequestTick) { _, _ in beginCompose(.reply) }
        .onChange(of: appState.replyAllRequestTick) { _, _ in beginCompose(.replyAll) }
        .onChange(of: appState.forwardRequestTick) { _, _ in beginCompose(.forward) }
        // Once a body is available, consume a pending scroll restore from the
        // nav cursor (a no-op on a normal open). Both branches guard against
        // re-consuming, so whichever body type lands first wins.
        .onChange(of: model?.htmlBody) { _, _ in consumeScrollRestoreIfReady() }
        .onChange(of: model?.plainText) { _, _ in consumeScrollRestoreIfReady() }
        .onAppear {
            BodyFetchLog.appear(uid: envelope.uid, modelExists: model != nil)
            // Drive the body fetch from `.onAppear` rather than SwiftUI's
            // `.task` modifier. On iPhone-compact NavigationStack push,
            // `.task` fires twice for the same view identity with
            // unpredictable cancellation timing — the live instance can
            // race the doomed one, or both can be cancelled at entry,
            // leaving the view stuck on a spinner. `.onAppear` only fires
            // when the view actually appears, and the load itself runs on
            // an unstructured Task owned by the view model, immune to
            // SwiftUI's `.task` cancellation. The model cancels that Task
            // in `onDisappear()` when the view is genuinely going away.
            let activeModel: MessageDetailViewModel
            if let existing = model {
                activeModel = existing
            } else {
                guard let client = appState.client else { return }
                let newModel = MessageDetailViewModel(
                    folder: folder,
                    envelope: envelope,
                    client: client,
                    preferences: preferences
                )
                // Relay flag changes (\Seen toggles) up to AppState so the
                // list view's `.onChange` handler can flip the row's bold
                // styling and unread dot without waiting for the next
                // IDLE / pull-to-refresh.
                let folderPath = folder.path
                let uid = envelope.uid
                newModel.onFlagChanged = { [weak appState] flag, added in
                    appState?.signalFlagChange(
                        folderPath: folderPath,
                        uid: uid,
                        flag: flag,
                        added: added
                    )
                }
                // Bracket each flag write so the list shields the optimistic
                // flag from a refresh that lands before the write resolves
                // (the cross-view analogue of the list's own pending-flag
                // shield). Folder-keyed so a UID collision across mailboxes
                // can't mis-shield an unrelated row.
                newModel.onFlagWriteInFlight = { [weak appState] inFlight in
                    appState?.setFlagWrite(
                        folderPath: folderPath,
                        uid: uid,
                        inFlight: inFlight
                    )
                }
                // Likewise bracket archive / trash / move so the list keeps
                // the optimistically-pruned row gone until the move resolves,
                // rather than letting a mid-move refresh resurrect it.
                newModel.onMoveInFlight = { [weak appState] inFlight in
                    appState?.setMoveInFlight(
                        folderPath: folderPath,
                        uid: uid,
                        inFlight: inFlight
                    )
                }
                model = newModel
                activeModel = newModel
            }
            activeModel.startLoadIfNeeded()
        }
        .onDisappear { model?.onDisappear() }
    }

    @ViewBuilder
    private func sourceSheet(initialTab: MessageSourceSheet.Tab) -> some View {
        if let model {
            MessageSourceSheet(
                model: model,
                initialTab: initialTab,
                onClose: { sourceSheetTab = nil }
            )
        }
    }

    @ViewBuilder
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Subject appears in full here because the list truncates it;
            // the surrounding ScrollView in `body` lets the header wrap
            // freely and scroll when needed.
            Text(envelope.subject ?? "(no subject)")
                .font(.title3)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 12) {
                if let apiClient = appState.client?.apiClient {
                    AvatarView(sender: envelope.from.first, apiClient: apiClient)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let from = envelope.from.first {
                        Text(headerFromLabel(for: from))
                            .font(.headline)
                            .task(id: "\(from.mailbox.lowercased())@\(from.host.lowercased())") {
                                await hydrateSenderContactName(for: from)
                            }
                            .contextMenu { addressMenu(for: from) }
                    }
                    if !envelope.to.isEmpty {
                        recipientFlow(label: "To:", addresses: envelope.to)
                    }
                    if !envelope.cc.isEmpty {
                        recipientFlow(label: "Cc:", addresses: envelope.cc)
                    }
                    if let date = envelope.date ?? envelope.internalDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Sender-authentication verdicts, rendered in all three
                    // states ("Not verified" muted). Bucketing lives in
                    // CabalmailKit; see `AuthResultsLine`.
                    AuthResultsLine(results: envelope.authResults)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // The detail view exposes seven action buttons. On macOS they live in the
    // top toolbar, which has room for all of them; on iOS/visionOS they would
    // crowd the inline title and hide the subject, so we route them to a bottom
    // bar where they're also easier to reach with a thumb. That bar sizes to
    // its content and only holds `ReaderToolbarLayout.capacity` items before
    // the system compacts the tail into an overflow control of its own, so the
    // two display toggles ride in our own overflow menu instead. See
    // `ReaderToolbarLayout` — anything new belongs in the overflow menu too.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS) || os(visionOS)
        // `drawsOwnActionBar` takes the bar over on iOS 27 at regular width,
        // where a `.bottomBar` group would span the whole window rather than
        // the reading pane (see `readerActionBar`).
        if !drawsOwnActionBar {
            ToolbarItemGroup(placement: .bottomBar) {
                let actions = ReaderToolbarLayout.bottomBar(
                    leading: model?.leadingToolbarAction ?? .reply
                )
                ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                    if index > 0 { Spacer() }
                    bottomBarButton(for: action)
                }
            }
        }
        #else
        if model?.leadingToolbarAction == .editDraft {
            ToolbarItem { editDraftButton }
        } else {
            ToolbarItem { replyButton }
        }
        ToolbarItem { seenButton }
        ToolbarItem { flagButton }
        ToolbarItem { remoteContentButton }
        ToolbarItem { readerModeButton }
        ToolbarItem { disposeButton }
        ToolbarItem { overflowMenuButton }
        #endif
    }

}

// Toolbar-button builders and dispose helpers live in
// `MessageDetailView+Toolbar.swift` so this file stays under SwiftLint's
// 400-line file_length cap.
