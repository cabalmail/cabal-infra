// Push notifications ship on iOS and macOS only (see PushRegistrar.swift);
// the visionOS build of the shared Cabalmail target must not compile this,
// so the Settings form on visionOS simply has no Notifications section.
#if os(iOS) || os(macOS)
import SwiftUI
import UserNotifications
import CabalmailKit
#if os(macOS)
import OSLog
import ServiceManagement
#endif

/// "Notifications" section of the Settings form (push phase 5).
///
/// The master toggle drives `PushRegistrar.enablePush` / `disablePush`; the
/// scope picker and folder list persist through
/// `PushRegistrar.updateFolderScope`, which re-registers the stored token
/// immediately so the server row tracks the choice without waiting for the
/// next launch. All of this state is per device by design — the server keeps
/// the folder list on this device's token row, so there is no
/// get/set_preferences mirror.
///
/// Every row is always present (disabled, never removed) and the checkmark
/// in the folder picker reserves its space when unselected, so no state
/// change shifts a control's position or size.
struct NotificationSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    /// The user's intent (inverse of `PushSettings.isUserDisabled`). When
    /// the OS-level permission is denied the toggle *displays* off and
    /// disabled regardless, but the stored intent is kept so re-granting
    /// permission in Settings restores the previous choice.
    @State private var pushEnabled = !PushSettings.isUserDisabled
    @State private var scope = PushSettings.folderScope
    @State private var chosenFolders = Set(PushSettings.chosenFolders)
    @State private var systemDenied = false
    #if os(macOS)
    // The macOS Settings scene has no NavigationStack (by design — see
    // SettingsView's top comment), so a NavigationLink would render
    // permanently disabled. Present the folder picker as a sheet instead,
    // same pattern as the Acknowledgements row.
    @State private var showingFolderPicker = false
    // Mac residency: Macs get silent pushes and the running app enriches
    // them, so a quit app gets no notification — these two rows exist to
    // make "quit" rare. The login-item toggle reflects the system's
    // actual `SMAppService` status (default: unregistered until the user
    // opts in); the menu-bar toggle is the `isInserted` binding for the
    // status item `CabalmailMacApp` declares.
    @State private var loginItemStatus = SMAppService.mainApp.status
    @AppStorage(menuBarExtraDefaultsKey) private var showInMenuBar = true
    private let residencyLog = Logger(
        subsystem: "com.cabalmail.Cabalmail",
        category: "login-item"
    )
    #endif

    var body: some View {
        Section {
            Toggle("New-mail notifications", isOn: enabledBinding)
                .disabled(systemDenied)
                .task { await refreshSystemPermission() }
                .onChange(of: scenePhase) { _, phase in
                    // Re-check after a round trip to Settings/System
                    // Settings, where the user may have (un)denied us.
                    guard phase == .active else { return }
                    Task { await refreshSystemPermission() }
                }
            Picker("Notify for", selection: scopeBinding) {
                Text("Inbox only").tag(PushFolderScope.inboxOnly)
                Text("All folders").tag(PushFolderScope.all)
                Text("Chosen folders").tag(PushFolderScope.custom)
            }
            .disabled(!controlsEnabled)
            chooseFoldersRow
                .disabled(!controlsEnabled || scope != .custom)
                .onChange(of: chosenFolders) { _, newValue in
                    PushRegistrar.shared.updateFolderScope(
                        scope,
                        chosenFolders: newValue.sorted()
                    )
                }
            #if os(macOS)
            // Deliberately not gated on `controlsEnabled`: residency is
            // motivated by notification coverage but useful without it
            // (menu-bar unread count, background mail polling).
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            Toggle("Show in menu bar", isOn: $showInMenuBar)
            #endif
        } header: {
            Text("Notifications")
        } footer: {
            // Always present (content swaps, structure doesn't) so the
            // sections below never reflow when the permission state changes.
            #if os(macOS)
            VStack(alignment: .leading, spacing: 6) {
                Text(footerText)
                Text(residencyFooterText)
            }
            #else
            Text(footerText)
            #endif
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var chooseFoldersRow: some View {
        #if os(macOS)
        Button {
            showingFolderPicker = true
        } label: {
            folderRowLabel
        }
        .sheet(isPresented: $showingFolderPicker) {
            NavigationStack {
                NotificationFolderPickerView(selection: $chosenFolders)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingFolderPicker = false }
                        }
                    }
            }
            .frame(minWidth: 360, minHeight: 420)
        }
        #else
        NavigationLink {
            NotificationFolderPickerView(selection: $chosenFolders)
        } label: {
            folderRowLabel
        }
        #endif
    }

    private var folderRowLabel: some View {
        LabeledContent("Choose Folders") {
            Text("\(chosenFolders.count) selected")
        }
    }

    // MARK: - Bindings and state

    /// The toggle, scope picker, and folder row are enabled together: all
    /// three are inert while notifications are off or denied at OS level.
    private var controlsEnabled: Bool {
        pushEnabled && !systemDenied
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { pushEnabled && !systemDenied },
            set: { newValue in
                pushEnabled = newValue
                Task {
                    if newValue {
                        let granted = await PushRegistrar.shared.enablePush()
                        if !granted {
                            // The OS said no (fresh denial or an earlier
                            // one): show that honestly instead of a lying
                            // "on" toggle.
                            pushEnabled = false
                            await refreshSystemPermission()
                        }
                    } else {
                        await PushRegistrar.shared.disablePush()
                    }
                }
            }
        )
    }

    private var scopeBinding: Binding<PushFolderScope> {
        Binding(
            get: { scope },
            set: { newValue in
                scope = newValue
                PushRegistrar.shared.updateFolderScope(
                    newValue,
                    chosenFolders: chosenFolders.sorted()
                )
            }
        )
    }

    #if os(macOS)
    /// Honest launch-at-login toggle: registration is attempted, then the
    /// displayed state is re-read from the system rather than assumed —
    /// a denied or approval-gated registration reverts the toggle instead
    /// of lying "on".
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItemStatus == .enabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    let verb = newValue ? "register" : "unregister"
                    let reason = error.localizedDescription
                    residencyLog.error(
                        "Login item \(verb, privacy: .public) failed: \(reason, privacy: .public)"
                    )
                }
                loginItemStatus = SMAppService.mainApp.status
            }
        )
    }

    private var residencyFooterText: String {
        if loginItemStatus == .requiresApproval {
            return "Login item waiting for approval — allow Cabalmail in System Settings > General > Login Items."
        }
        return "Launching at login keeps new-mail notifications working without opening Cabalmail."
    }
    #endif

    private var footerText: String {
        if systemDenied {
            #if os(macOS)
            return "Notifications for Cabalmail are turned off in System Settings > Notifications."
            #else
            return "Notifications for Cabalmail are turned off in Settings > Notifications."
            #endif
        }
        return "Notifies about new mail in the selected folders, even when Cabalmail isn't running."
    }

    private func refreshSystemPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemDenied = settings.authorizationStatus == .denied
        #if os(macOS)
        // Same round-trip logic as the permission: the user may have
        // approved (or removed) the login item in System Settings.
        loginItemStatus = SMAppService.mainApp.status
        #endif
    }
}

/// Multi-select folder list backing the "Chosen folders" scope. Loads every
/// folder (subscribed or not — a notification scope is orthogonal to sidebar
/// subscription), sorted like the sidebar: INBOX first, user folders in tree
/// order, system folders last. Selection writes through the binding; the
/// owning section persists and re-registers on each change.
struct NotificationFolderPickerView: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: Set<String>

    @State private var folders: [Folder] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("Notification Folders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading folders…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(folders) { folder in
                Button {
                    toggle(folder.path)
                } label: {
                    row(for: folder)
                }
                .buttonStyle(.plain)
            }
            #if os(iOS)
            .listStyle(.plain)
            #endif
        }
    }

    @ViewBuilder
    private func row(for folder: Folder) -> some View {
        let depth = FolderTree.depth(for: folder)
        HStack(spacing: 8) {
            Image(systemName: icon(for: folder))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.body)
                if depth > 0 {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // Opacity, not conditional presence: the checkmark keeps its
            // slot so rows don't shift as folders are (de)selected.
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(selection.contains(folder.path) ? 1 : 0)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
    }

    private func toggle(_ path: String) {
        if selection.contains(path) {
            // Never allow an empty selection: the wire format has no "no
            // folders" value — an empty enabled_folders list is the server's
            // "reset to inbox only", which would contradict what this screen
            // shows. Turning notifications off entirely is the master
            // toggle's job, so the last selected folder stays put.
            guard selection.count > 1 else { return }
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }

    private func icon(for folder: Folder) -> String {
        switch folder.path {
        case "INBOX":   return "tray"
        case "Sent":    return "paperplane"
        case "Drafts":  return "pencil.line"
        case "Trash":   return "trash"
        case "Junk":    return "exclamationmark.shield"
        case "Archive": return "archivebox"
        default:        return "folder"
        }
    }

    @MainActor
    private func load() async {
        guard let client = appState.client else {
            isLoading = false
            errorMessage = "Sign in to load folders."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let all = try await client.imapClient.listFolders()
            folders = sortForPicker(all)
        } catch {
            errorMessage = "Couldn't load folders: \(error.localizedDescription)"
        }
    }

    /// Same visible order as the sidebar and MoveToFolderSheet — INBOX
    /// pinned first, user folders in tree order, system folders last — but
    /// nothing is filtered out: any folder can be a notification source.
    private func sortForPicker(_ input: [Folder]) -> [Folder] {
        FolderTree.sidebarOrder(input)
    }
}
#endif
