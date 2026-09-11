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
    /// Whether to offer the "This folder only" toggle. The folder list scopes
    /// to its folder; the global search surface has no anchor folder, so it
    /// hides the toggle and always searches cross-folder.
    let allowFolderScope: Bool
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
        allowFolderScope: Bool = true,
        onApply: @escaping (MessageSearchFilters) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._filters = filters
        self.currentFolderName = currentFolderName
        self.allowFolderScope = allowFolderScope
        self.onApply = onApply
        self.onCancel = onCancel
        let initial = filters.wrappedValue
        self._draft = State(initialValue: initial)
        self._sinceEnabled = State(initialValue: initial.since != nil)
        self._beforeEnabled = State(initialValue: initial.before != nil)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Filters")
                #if !os(macOS)
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

    // MARK: - Platform layouts
    //
    // `Form` is kept for iOS/visionOS, where its grouped list style insets
    // the rows and renders the section headers as group captions. On macOS
    // the same `Form` promotes each text field's title into an external
    // leading label column, right-aligned to a column edge, and gives the
    // rows no horizontal margins: "Subject" landed 0 pt from the sheet's left
    // border and all three fields ran flush to its right one (#1501). macOS
    // therefore gets the hand-built layout the create sheets share,
    // `MacSheetForm`.

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macContent
        #else
        formContent
        #endif
    }

    #if os(macOS)
    private var macContent: some View {
        MacSheetForm {
            MacSheetSection(caption: "Recipients") {
                // The two fields share a caption, so each keeps a visible
                // label — in a column inside the margins rather than one the
                // Form hangs off the sheet's edge.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("From")
                            .gridColumnAlignment(.trailing)
                        fromField
                    }
                    GridRow {
                        Text("To")
                        toField
                    }
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            MacSheetSection(caption: "Subject") {
                // The caption already says "Subject"; hidden, the field's
                // own title survives for VoiceOver.
                subjectField
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            MacSheetSection(caption: "Date range") {
                // Each picker stays on its checkbox's row, dimmed until the
                // box is ticked, so ticking one moves nothing below it.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Toggle("Since", isOn: $sinceEnabled)
                        sincePicker
                            .disabled(!sinceEnabled)
                    }
                    GridRow {
                        Toggle("Before", isOn: $beforeEnabled)
                        beforePicker
                            .disabled(!beforeEnabled)
                    }
                }
            }
            MacSheetSection(caption: "Flags") {
                flagToggles
            }
            if allowFolderScope {
                MacSheetSection(caption: "Scope") {
                    folderScopeToggle
                    Text(folderScopeFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .sectionFooter()
                }
            }
        }
    }
    #else
    private var formContent: some View {
        Form {
            Section("Recipients") {
                fromField
                toField
            }
            Section("Subject") {
                subjectField
            }
            Section("Date range") {
                Toggle("Since", isOn: $sinceEnabled)
                if sinceEnabled {
                    sincePicker
                }
                Toggle("Before", isOn: $beforeEnabled)
                if beforeEnabled {
                    beforePicker
                }
            }
            Section("Flags") {
                flagToggles
            }
            if allowFolderScope {
                Section {
                    folderScopeToggle
                } footer: {
                    Text(folderScopeFooter)
                        .sectionFooter()
                }
            }
        }
    }
    #endif

    // MARK: - Controls shared by both layouts

    private var fromField: some View {
        TextField("From", text: $draft.from, prompt: Text("sender@example.com"))
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
    }

    private var toField: some View {
        TextField("To", text: $draft.to, prompt: Text("recipient@example.com"))
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
    }

    private var subjectField: some View {
        TextField("Subject", text: $draft.subject, prompt: Text("invoice"))
    }

    private var sincePicker: some View {
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

    private var beforePicker: some View {
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

    @ViewBuilder
    private var flagToggles: some View {
        Toggle("Unread", isOn: $draft.unread)
        Toggle("Flagged", isOn: $draft.flagged)
        Toggle("Has attachment", isOn: $draft.hasAttachment)
    }

    private var folderScopeToggle: some View {
        Toggle("This folder only", isOn: $draft.thisFolderOnly)
    }

    private var folderScopeFooter: String {
        draft.thisFolderOnly
            ? "Search restricted to \(currentFolderName)."
            : "Search every subscribed folder except Trash."
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
