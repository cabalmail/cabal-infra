import SwiftUI
import CabalmailKit

// The Composing, Actions, and About category screens, split out of
// `SettingsView.swift` so that file stays within the file-length budget.
// Each is a self-contained detail destination for `SettingsCategoryDetail`.

// MARK: - Composing

/// The Default From picker is seeded asynchronously from the address list on
/// appear so the picker stays in sync with "Request New" in the Addresses
/// tab without an explicit message-passing step.
struct ComposingSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    @State private var availableAddresses: [Address] = []
    @State private var isLoadingAddresses = false

    // Display name is a server-side preference (shared with the React app;
    // the /send Lambda composes the From header from it), not a Preferences
    // entry. The field stays disabled until the server value has loaded so
    // a flaky network can't silently clobber an existing name with "".
    @State private var displayName = ""
    @State private var displayNameLoaded = false
    @State private var lastSavedDisplayName: String?
    @State private var displayNameSaveTask: Task<Void, Never>?

    var body: some View {
        @Bindable var preferences = preferences
        SettingsForm(title: "Composing") {
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
            } footer: {
                Text("Name appears as the display name on mail you send, e.g. \"Chris Carr <address>\".")
                    .sectionFooter()
            }
        }
        .task {
            await loadAddresses()
            await loadDisplayName()
        }
        .refreshable {
            await loadAddresses(force: true)
            await loadDisplayName()
        }
    }

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

// MARK: - Actions

struct ActionsSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        SettingsForm(title: "Actions") {
            Section {
                // A segmented picker drops its own title on iOS/iPadOS, so
                // the row that names the setting has to supply it — the two
                // rows below keep the default style and so keep their
                // labels, and macOS renders this one's label either way.
                // `LabeledContent` fixes the platform that loses it without
                // restyling the one that doesn't. The title stays on the
                // `Picker` for VoiceOver, the same split `ComposerBody` and
                // `MessageSourceSheet` already make.
                LabeledContent("Dispose action") {
                    Picker("Dispose action", selection: $preferences.disposeAction) {
                        Text("Archive").tag(DisposeAction.archive)
                        Text("Trash").tag(DisposeAction.trash)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Picker("After disposing", selection: $preferences.disposeAdvance) {
                    Text("Go to next message").tag(DisposeAdvance.next)
                    Text("Go to next unread").tag(DisposeAdvance.nextUnread)
                    Text("Go to previous unread").tag(DisposeAdvance.previousUnread)
                    Text("Go to first unread").tag(DisposeAdvance.firstUnread)
                }
                Picker("After marking read", selection: $preferences.markReadAdvance) {
                    Text("Stay here").tag(MarkReadAdvance.stay)
                    Text("Go to next unread").tag(MarkReadAdvance.nextUnread)
                    Text("Go to previous unread").tag(MarkReadAdvance.previousUnread)
                    Text("Go to first unread").tag(MarkReadAdvance.firstUnread)
                }
            } footer: {
                Text("Which message the reading pane opens after you archive, delete, or mark read from it.")
                    .sectionFooter()
            }
        }
    }
}

// MARK: - About

/// App version/build, the third-party Acknowledgements screen, and an
/// issue-report link. Acknowledgements is a plain push on every platform
/// now that the detail column supplies a `NavigationStack` — the macOS
/// sheet workaround for the stack-less Settings scene is gone.
struct AboutSettingsView: View {
    var body: some View {
        SettingsForm(title: "About") {
            Section {
                LabeledContent("Version", value: Self.marketingVersion)
                LabeledContent("Build", value: Self.buildNumber)
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                Link(
                    destination: URL(string: "https://github.com/cabalmail/cabal-infra/issues")!
                ) {
                    Label("Report an issue", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? CabalmailKit.version
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
