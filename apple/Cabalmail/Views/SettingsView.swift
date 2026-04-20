import SwiftUI
import CabalmailKit

/// Settings tab (iPhone / iPad / visionOS) and Settings scene (macOS).
///
/// Grouped into the five sections the plan calls out — Account, Reading,
/// Composing, Actions, Appearance — plus an About block. Every knob binds
/// directly to the `Preferences` instance hoisted at the App level; writes
/// round-trip through `NSUbiquitousKeyValueStore` so they follow the user
/// to their other devices without any extra plumbing in this view.
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

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Settings")
                .task { await loadAddresses() }
                .refreshable { await loadAddresses(force: true) }
        }
    }

    @ViewBuilder
    private var form: some View {
        @Bindable var preferences = preferences
        Form {
            accountSection
            readingSection(bindable: preferences)
            composingSection(bindable: preferences)
            actionsSection(bindable: preferences)
            appearanceSection(bindable: preferences)
            diagnosticsSection(bindable: preferences)
            aboutSection
        }
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
                Text("After delay (2s)").tag(MarkAsReadBehavior.afterDelay)
            }
            Picker("Load remote content", selection: $preferences.loadRemoteContent) {
                Text("Off").tag(LoadRemoteContentPolicy.off)
                Text("Ask").tag(LoadRemoteContentPolicy.ask)
                Text("Always").tag(LoadRemoteContentPolicy.always)
            }
        }
    }

    @ViewBuilder
    private func composingSection(bindable preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Section("Composing") {
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

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.marketingVersion)
            LabeledContent("Build", value: Self.buildNumber)
            Link(
                destination: URL(string: "https://github.com/cabalmail/cabal-infra/issues")!
            ) {
                Label("Report an issue", systemImage: "arrow.up.right.square")
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
        }
    }

    // MARK: - About values

    private static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? CabalmailKit.version
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
