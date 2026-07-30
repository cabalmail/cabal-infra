import SwiftUI
import CabalmailKit

/// Settings tab (iPhone / iPad / visionOS) and Settings scene (macOS).
///
/// Grouped into the five sections the plan calls out — Account, Reading,
/// Composing, Actions, Appearance — plus an About block. Every knob binds
/// directly to the `Preferences` instance hoisted at the App level; the
/// session's `PreferencesSyncCoordinator` pushes writes to the server so
/// they follow the Cabalmail account to the user's other devices without
/// any extra plumbing in this view.
///
/// The Default From picker is seeded asynchronously from the address list
/// on appear so the picker stays in sync with "Request New" in the
/// Addresses tab without an explicit message-passing step.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    @State private var availableAddresses: [Address] = []
    @State private var isLoadingAddresses = false
    @State private var signOutInFlight = false

    // Display name is a server-side preference (shared with the React app;
    // the /send Lambda composes the From header from it), not a Preferences
    // entry. The field stays disabled until the server value has loaded so
    // a flaky network can't silently clobber an existing name with "".
    @State private var displayName = ""
    @State private var displayNameLoaded = false
    @State private var lastSavedDisplayName: String?
    @State private var displayNameSaveTask: Task<Void, Never>?

    var body: some View {
        #if os(macOS)
        // macOS hosts this view inside the Settings scene's TabView, which
        // already supplies the window chrome. A NavigationStack here would
        // duplicate the chrome and prevent the Form from scrolling when the
        // window is shorter than the content. Using `.formStyle(.grouped)`
        // gives the standard System-Settings-style padded card layout.
        form
            .task {
                await loadAddresses()
                await loadDisplayName()
            }
            .refreshable {
                await loadAddresses(force: true)
                await loadDisplayName()
            }
        #else
        NavigationStack {
            form
                .navigationTitle("Settings")
                .settingsSheetDoneButton()
                .task {
                    await loadAddresses()
                    await loadDisplayName()
                }
                .refreshable {
                    await loadAddresses(force: true)
                    await loadDisplayName()
                }
        }
        #endif
    }

    @ViewBuilder
    private var form: some View {
        @Bindable var preferences = preferences
        Form {
            accountSection
            readingSection(bindable: preferences)
            composingSection(bindable: preferences)
            actionsSection(bindable: preferences)
            // Push ships on iOS and macOS only; the visionOS build has no
            // PushRegistrar, so the section is compiled out with it.
            #if os(iOS) || os(macOS)
            NotificationSettingsSection()
            #endif
            appearanceSection(bindable: preferences)
            diagnosticsSection(bindable: preferences)
            AboutSettingsSection()
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
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

    @ViewBuilder
    private func readingSection(bindable preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Section("Reading") {
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

    @ViewBuilder
    private func composingSection(bindable preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Section {
            TextField("Name (optional)", text: $displayName)
                .disabled(!displayNameLoaded)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.words)
                #endif
                .onChange(of: displayName) { _, newValue in
                    scheduleDisplayNameSave(newValue)
                }
            Picker("Default From", selection: defaultFromBinding(preferences: preferences)) {
                Text("None").tag(Optional<String>.none)
                if isLoadingAddresses && availableAddresses.isEmpty {
                    Text("Loading…").tag(Optional<String>.none)
                } else {
                    ForEach(availableAddresses) { address in
                        Text(address.address).tag(Optional(address.address))
                    }
                }
            }
            TextField(
                "Signature (optional)",
                text: $preferences.signature,
                axis: .vertical
            )
            .lineLimit(1...6)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.sentences)
            #endif
        } header: {
            Text("Composing")
        } footer: {
            Text("Name appears as the display name on mail you send, e.g. \"Chris Carr <address>\".")
        }
    }

    @ViewBuilder
    private func actionsSection(bindable preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Section("Actions") {
            Picker("Dispose action", selection: $preferences.disposeAction) {
                Text("Archive").tag(DisposeAction.archive)
                Text("Trash").tag(DisposeAction.trash)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func appearanceSection(bindable preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Section("Appearance") {
            Picker("Theme", selection: $preferences.theme) {
                Text("System").tag(AppTheme.system)
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func diagnosticsSection(bindable preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Section("Diagnostics") {
            Toggle("Crash reports", isOn: Binding(
                get: { preferences.crashReportingEnabled },
                set: { newValue in
                    preferences.crashReportingEnabled = newValue
                    // Flip the live subscription immediately so turning it
                    // on during a repro session captures the next hang /
                    // crash without a relaunch.
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

    // MARK: - Bindings

    /// Wraps the `defaultFromAddress` preference for the picker, with a
    /// safety check: if the previously-selected address was revoked from
    /// another device, the picker falls back to "None" instead of showing
    /// a dangling selection.
    private func defaultFromBinding(preferences: Preferences) -> Binding<String?> {
        Binding(
            get: {
                guard let selected = preferences.defaultFromAddress else { return nil }
                if availableAddresses.isEmpty { return selected }
                return availableAddresses.contains { $0.address == selected } ? selected : nil
            },
            set: { preferences.defaultFromAddress = $0 }
        )
    }

    // MARK: - Data loading

    private func loadAddresses(force: Bool = false) async {
        guard let client = appState.client else { return }
        isLoadingAddresses = true
        defer { isLoadingAddresses = false }
        if let addresses = try? await client.addresses(forceRefresh: force) {
            availableAddresses = addresses
                .sorted { $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending }
            // Actually clear a dangling default (revoked, or leaked in from
            // another account pre-scoping) rather than leaving the masked
            // "None" the picker binding shows — the underlying value would
            // otherwise keep pre-filling compose, and selecting "None" can't
            // remove it because the picker already reads as "None".
            preferences.reconcileDefaultFromAddress(available: addresses.map(\.address))
        }
    }

    private func loadDisplayName() async {
        guard let client = appState.client else { return }
        if let name = try? await client.displayName() {
            lastSavedDisplayName = name
            displayName = name
            displayNameLoaded = true
        }
    }

    /// Debounced save mirroring the React app's 1s-after-last-keystroke
    /// behavior. `lastSavedDisplayName` suppresses the echo when `.onChange`
    /// fires for the value the load (or a completed save) just put in place.
    private func scheduleDisplayNameSave(_ value: String) {
        guard displayNameLoaded, value != lastSavedDisplayName else { return }
        displayNameSaveTask?.cancel()
        displayNameSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let client = appState.client else { return }
            do {
                try await client.setDisplayName(value)
                lastSavedDisplayName = value
            } catch {
                // Transient failure - the next edit (or settings visit) retries.
            }
        }
    }
}

/// About block for the Settings form: app version/build, the third-party
/// Acknowledgements screen, and an issue-report link. Extracted from
/// `SettingsView` so that view's body stays within the type-body-length
/// budget; it holds no state of its own.
private struct AboutSettingsSection: View {
    #if os(macOS)
    // The macOS Settings scene hosts this form without a NavigationStack (by
    // design — see SettingsView's top comment; one there breaks Form
    // scrolling and duplicates window chrome), so a NavigationLink renders
    // permanently disabled. Present Acknowledgements as a sheet on macOS;
    // iOS/visionOS push it onto their Settings NavigationStack.
    @State private var showingAcknowledgements = false
    #endif

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Self.marketingVersion)
            LabeledContent("Build", value: Self.buildNumber)
            acknowledgementsRow
            Link(
                destination: URL(string: "https://github.com/cabalmail/cabal-infra/issues")!
            ) {
                Label("Report an issue", systemImage: "arrow.up.right.square")
            }
        }
    }

    @ViewBuilder
    private var acknowledgementsRow: some View {
        #if os(macOS)
        Button {
            showingAcknowledgements = true
        } label: {
            Label("Acknowledgements", systemImage: "doc.text")
        }
        .sheet(isPresented: $showingAcknowledgements) {
            NavigationStack {
                AcknowledgementsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAcknowledgements = false }
                        }
                    }
            }
            .frame(minWidth: 480, minHeight: 420)
        }
        #else
        NavigationLink {
            AcknowledgementsView()
        } label: {
            Label("Acknowledgements", systemImage: "doc.text")
        }
        #endif
    }

    private static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? CabalmailKit.version
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
