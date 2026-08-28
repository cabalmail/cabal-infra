import SwiftUI
import CabalmailKit

/// The settings surface for every platform: a category list with a detail
/// pane, System-Settings style.
///
/// Wide layouts (the macOS Settings window, the visionOS Settings tab) show
/// the categories in a leading column and the selected category's form in
/// the detail column. Narrow layouts (the iPhone Settings tab and the iPad
/// settings sheet, whose content is compact-width even on large iPads)
/// collapse to the category list alone; each category pushes as its own
/// screen with a back chevron.
///
/// The detail column carries its own `NavigationStack`, so pushes inside a
/// category (rule editor, folder picker, acknowledgements, debug log) work
/// on every platform — including the macOS Settings scene, which has no
/// stack of its own and used to need sheet workarounds for these.
///
/// Every knob binds directly to the `Preferences` instance hoisted at the
/// App level; the session's `PreferencesSyncCoordinator` pushes writes to
/// the server so they follow the Cabalmail account to the user's other
/// devices without any extra plumbing in these views.
struct SettingsView: View {
    @State private var selection: SettingsCategory? = SettingsView.initialSelection

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
        }
    }

    private var sidebar: some View {
        List(SettingsCategory.available, selection: $selection) { category in
            Label(category.title, systemImage: category.systemImage)
        }
        .navigationTitle("Settings")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 200)
        #else
        .settingsSheetDoneButton()
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            SettingsCategoryDetail(category: selection)
                #if !os(macOS)
                .settingsSheetDoneButton()
                #endif
        } else {
            Text("Select a category")
                .foregroundStyle(.secondary)
        }
    }

    /// macOS and visionOS open wide enough for both columns, so they land on
    /// Account instead of an empty detail pane. iOS (the iPhone tab and the
    /// iPad sheet) collapses to the list; a preselected category there would
    /// skip past the list straight onto a detail screen.
    private static var initialSelection: SettingsCategory? {
        #if os(iOS)
        nil
        #else
        .account
        #endif
    }
}

/// The selectable settings categories, in presentation order.
enum SettingsCategory: CaseIterable, Identifiable, Hashable {
    case account, reading, composing, rules, flags, actions, notifications
    case appearance, diagnostics, about

    var id: Self { self }

    /// Categories present on this platform. Push ships on iOS and macOS only
    /// (the visionOS build has no PushRegistrar), so visionOS has no
    /// Notifications category — same condition that compiles out
    /// `NotificationSettingsSection`.
    static var available: [SettingsCategory] {
        #if os(iOS) || os(macOS)
        allCases
        #else
        allCases.filter { $0 != .notifications }
        #endif
    }

    var title: String {
        switch self {
        case .account: "Account"
        case .reading: "Reading"
        case .composing: "Composing"
        case .rules: "Rules"
        case .flags: "Flags"
        case .actions: "Actions"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .reading: "envelope.open"
        case .composing: "square.and.pencil"
        case .rules: "list.bullet.rectangle"
        case .flags: "flag"
        case .actions: "archivebox"
        case .notifications: "bell.badge"
        case .appearance: "paintbrush"
        case .diagnostics: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}

/// Routes a category to its detail screen. Rules goes straight to the rules
/// list — the category row *is* the entry point, with no launcher row in
/// between. Each destination names itself via `navigationTitle` so the
/// collapsed (narrow) presentation titles the pushed screen.
private struct SettingsCategoryDetail: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .account: AccountSettingsView()
        case .reading: ReadingSettingsView()
        case .composing: ComposingSettingsView()
        case .rules: RulesView()
        case .flags: FlagPaletteSettingsView()
        case .actions: ActionsSettingsView()
        case .notifications:
            #if os(iOS) || os(macOS)
            NotificationsSettingsView()
            #endif
        case .appearance: AppearanceSettingsView()
        case .diagnostics: DiagnosticsSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

/// Shared chrome for the category detail screens: a `Form` with the grouped
/// (System-Settings card) style on macOS and an inline title on iOS /
/// visionOS, so drilled-in screens read as sub-pages of Settings.
struct SettingsForm<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .navigationTitle(title)
            #if os(macOS)
            .formStyle(.grouped)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

// MARK: - Account

private struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var signOutInFlight = false

    var body: some View {
        SettingsForm(title: "Account") {
            Section {
                LabeledContent("Signed in as") {
                    Text(appState.lastUsername.isEmpty ? "—" : appState.lastUsername)
                        .foregroundStyle(.secondary)
                }
                if !appState.controlDomain.isEmpty {
                    LabeledContent("Server") {
                        Text(appState.controlDomain)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) {
                    Task {
                        signOutInFlight = true
                        defer { signOutInFlight = false }
                        await appState.signOut()
                    }
                } label: {
                    HStack {
                        Text("Sign Out")
                        Spacer()
                        if signOutInFlight {
                            ProgressView()
                        }
                    }
                }
                .disabled(signOutInFlight)
            }
        }
    }
}

// MARK: - Reading

private struct ReadingSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsForm(title: "Reading") {
            Section {
                Picker("Mark as read", selection: $preferences.markAsRead) {
                    Text("Manual").tag(MarkAsReadBehavior.manual)
                    Text("On open").tag(MarkAsReadBehavior.onOpen)
                }
                Picker("Load remote content", selection: $preferences.loadRemoteContent) {
                    Text("Off").tag(LoadRemoteContentPolicy.off)
                    Text("Ask").tag(LoadRemoteContentPolicy.ask)
                    Text("Always").tag(LoadRemoteContentPolicy.always)
                }
                Picker("Default view", selection: $preferences.defaultBodyRenderMode) {
                    Text("Original").tag(BodyRenderMode.original)
                    Text("Reader").tag(BodyRenderMode.reader)
                }
                Picker("Folder counts", selection: $preferences.folderCountDisplay) {
                    Text("Unread").tag(FolderCountDisplay.unread)
                    Text("Total").tag(FolderCountDisplay.total)
                    Text("Unread / total").tag(FolderCountDisplay.both)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsForm(title: "Appearance") {
            Section {
                // The row label is the only thing naming this control on iOS
                // (a segmented picker drops its own title there), and
                // VoiceOver reads the segments bare — so the title stays on
                // the `Picker` while `LabeledContent` supplies the visible
                // label. Same split `ComposerBody` and `MessageSourceSheet`
                // already make.
                LabeledContent("Theme") {
                    Picker("Theme", selection: $preferences.theme) {
                        Text("System").tag(AppTheme.system)
                        Text("Light").tag(AppTheme.light)
                        Text("Dark").tag(AppTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        SettingsForm(title: "Diagnostics") {
            Section {
                Toggle("Crash reports", isOn: Binding(
                    get: { preferences.crashReportingEnabled },
                    set: { newValue in
                        preferences.crashReportingEnabled = newValue
                        // Flip the live subscription immediately so turning
                        // it on during a repro session captures the next
                        // hang / crash without a relaunch.
                        appState.client?.setCrashReportingEnabled(newValue)
                    }
                ))
                NavigationLink {
                    DebugLogView()
                } label: {
                    Label("Debug Log", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
    }
}
