import SwiftUI
import CabalmailKit

/// Filter form presented as a sheet (iPhone) or popover (iPad / macOS)
/// over the message list. Mirrors the React webmail's expandable filter
/// panel (`react/admin/src/Email/Search/index.jsx`): From / To /
/// Subject text fields, Since / Before date pickers, Unread / Flagged /
/// Has attachment / This folder only checkboxes, plus Reset and Apply
/// actions.
///
/// The sheet edits a local snapshot of the filters and only commits to
/// the model when the user taps Apply — matching the React behavior of
/// "Apply re-runs the search; typing alone doesn't hammer the Lambda."
/// Reset wipes the local snapshot back to defaults but doesn't run a
/// search; the user has to Apply (or Cancel out and submit the search
/// bar) to see the cleared filters take effect.
struct SearchFiltersSheet: View {
    @Binding var filters: MessageSearchFilters
    /// Display name for the "This folder only" toggle's helper text so
    /// the user sees which folder they're scoping to.
    let currentFolderName: String
    /// Fires when the user taps Apply. The sheet hands the modified
    /// snapshot back to the caller, which assigns to the view-model's
    /// `searchFilters` and re-runs the search.
    let onApply: (MessageSearchFilters) -> Void
    /// Fires when the user dismisses the sheet without applying.
    let onCancel: () -> Void

    @State private var draft: MessageSearchFilters
    @State private var sinceEnabled: Bool
    @State private var beforeEnabled: Bool

    init(
        filters: Binding<MessageSearchFilters>,
        currentFolderName: String,
        onApply: @escaping (MessageSearchFilters) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._filters = filters
        self.currentFolderName = currentFolderName
        self.onApply = onApply
        self.onCancel = onCancel
        let initial = filters.wrappedValue
        self._draft = State(initialValue: initial)
        self._sinceEnabled = State(initialValue: initial.since != nil)
        self._beforeEnabled = State(initialValue: initial.before != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipients") {
                    TextField("From", text: $draft.from, prompt: Text("sender@example.com"))
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                    TextField("To", text: $draft.to, prompt: Text("recipient@example.com"))
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                }
                Section("Subject") {
                    TextField("Subject", text: $draft.subject, prompt: Text("invoice"))
                }
                Section("Date range") {
                    Toggle("Since", isOn: $sinceEnabled)
                    if sinceEnabled {
                        DatePicker(
                            "Since date",
                            selection: Binding(
                                get: { draft.since ?? Date() },
                                set: { draft.since = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }
                    Toggle("Before", isOn: $beforeEnabled)
                    if beforeEnabled {
                        DatePicker(
                            "Before date",
                            selection: Binding(
                                get: { draft.before ?? Date() },
                                set: { draft.before = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    }
                }
                Section("Flags") {
                    Toggle("Unread", isOn: $draft.unread)
                    Toggle("Flagged", isOn: $draft.flagged)
                    Toggle("Has attachment", isOn: $draft.hasAttachment)
                }
                Section {
                    Toggle("This folder only", isOn: $draft.thisFolderOnly)
                } footer: {
                    Text(
                        draft.thisFolderOnly
                            ? "Search restricted to \(currentFolderName)."
                            : "Search every subscribed folder (Trash, Spam, Junk excluded)."
                    )
                }
            }
            .navigationTitle("Filters")
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 520)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Reset", role: .destructive, action: resetDraft)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: applyDraft)
                }
            }
            .onChange(of: sinceEnabled) { _, enabled in
                if !enabled {
                    draft.since = nil
                } else if draft.since == nil {
                    draft.since = Date()
                }
            }
            .onChange(of: beforeEnabled) { _, enabled in
                if !enabled {
                    draft.before = nil
                } else if draft.before == nil {
                    draft.before = Date()
                }
            }
        }
    }

    private func resetDraft() {
        draft = MessageSearchFilters()
        sinceEnabled = false
        beforeEnabled = false
    }

    private func applyDraft() {
        var snapshot = draft
        if !sinceEnabled { snapshot.since = nil }
        if !beforeEnabled { snapshot.before = nil }
        onApply(snapshot)
    }
}
