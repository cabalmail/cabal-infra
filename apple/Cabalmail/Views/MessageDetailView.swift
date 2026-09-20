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
    // The pane width at which the header grows its trailing column, scaled
    // with Dynamic Type so larger text needs a proportionally wider pane.
    // See `ReaderHeaderColumnPolicy` and `MessageDetailView+Header.swift`.
    @ScaledMetric(relativeTo: .caption2)
    var headerTrailingColumnMinWidth = ReaderHeaderColumnPolicy.baseMinPaneWidth
    #if os(iOS)
    // Drives `drawsOwnActionBar`: at regular width the reader shares the
    // window with the message list, and on iOS 27 a `.bottomBar` group
    // spreads across both columns. See `ReaderToolbarLayout`.
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    /// Set by `MailRootView` on an iPhone Duo's inner display; see
    /// `ReaderToolbarLayout.usesOwnActionBar` and `toolbarContent`.
    @Environment(\.hostHasFold) var hostHasFold
    // Measured width of the pane-scoped action bar, fed to
    // `ReaderToolbarLayout.ownBar` so the item set tracks the pane as the
    // user drags the split divider. Starts at 0, which draws the compact
    // five-item set for the frame before the first measurement lands.
    @State var readerPaneWidth: CGFloat = 0
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
            isOS27OrLater: isOS27OrLater,
            hostHasFold: hostHasFold
        )
        #else
        return false
        #endif
    }

    #if !os(macOS)
    /// Visibility the reader asks for on the section `TabView`'s bar: `.hidden`
    /// where that bar is the compact bottom one the action toolbar would
    /// collide with, `.automatic` on visionOS, where the same `TabView` is the
    /// leading ornament carrying the only entry points to Folders, Feeds,
    /// Addresses, Settings and Search. Rule in
    /// `SectionLayoutPolicy.readerHidesSectionTabBar`.
    var sectionTabBarVisibility: Visibility {
        SectionLayoutPolicy.readerHidesSectionTabBar(
            isVisionOS: SectionLayoutPolicy.isVisionOS
        ) ? .hidden : .automatic
    }
    #endif

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
                    headerBlock(paneWidth: proxy.size.width)
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
        // in `headerBlock` right below it.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Reading a message uses the full bottom edge for the action toolbar;
        // the compact-width section `TabView`'s bottom tab bar would otherwise
        // occlude it. The tab bar reappears automatically when the user swipes
        // back to the message list. Not on visionOS, whose section `TabView` is
        // the window's leading ornament and the only route to the other five
        // sections - see `SectionLayoutPolicy.readerHidesSectionTabBar`.
        .toolbar(sectionTabBarVisibility, for: .tabBar)
        #endif
        .toolbar { toolbarContent }
        // Window-scoped keyboard equivalents, hosted where the toolbar can't
        // evict them (see `disposeChordHost` / `readerChordHosts`).
        .background {
            disposeChordHost
            readerChordHosts
        }
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
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
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

    // The reader's action set, routed per platform. macOS draws every action
    // as its own top-toolbar button — eleven of them, ordered by reverse
    // demotion priority so that when the window gets too narrow AppKit's
    // trailing-first eviction into the » popup demotes Print first and the
    // filing actions last (#1047); there is no app-owned overflow menu there.
    // iOS/visionOS route a width-budgeted subset to a bottom bar (easier to
    // reach with a thumb; the extras ride `overflowMenuButton`). Both orders
    // live in `ReaderToolbarLayout`, which is where anything new gets a slot.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS) || os(visionOS)
        // `drawsOwnActionBar` takes the bar over on iOS 27 at regular width,
        // where a `.bottomBar` group would span the whole window rather than
        // the reading pane (see `readerActionBar`).
        if !drawsOwnActionBar {
            let actions = ReaderToolbarLayout.bottomBar(
                leading: model?.leadingToolbarAction ?? .reply
            )
            if hostHasFold, horizontalSizeClass == .regular {
                // iPhone Duo's inner display: top-placed items, the placement
                // the feed reader's items use, which the system lays out in
                // the vertical strip along the display edge (#1667). No
                // spacers — the strip is fixed-width and the system spaces
                // the items itself.
                ToolbarItemGroup {
                    ForEach(actions, id: \.self) { action in
                        toolbarButton(for: action)
                            .labelStyle(.iconOnly)
                    }
                }
            } else {
                ToolbarItemGroup(placement: .bottomBar) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        if index > 0 { Spacer() }
                        toolbarButton(for: action)
                            // The faces are `Label`s for the macOS » popup's
                            // sake; this bar draws them icon-only, as before.
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        #else
        // Both halves live in `MessageDetailView+MacToolbar.swift`.
        macToolbarLeading
        macToolbarTrailing
        #endif
    }

}

// Toolbar-button builders and dispose helpers live in
// `MessageDetailView+Toolbar.swift`, and the header block in
// `MessageDetailView+Header.swift`, so this file stays under SwiftLint's
// 400-line file_length cap.
