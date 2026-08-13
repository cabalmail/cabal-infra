import SwiftUI
import CabalmailKit

/// One labeled recipient field (To / Cc / Bcc) with two affordances on
/// top of the underlying `TextField`:
///
/// 1. Inline autocomplete: while the field is focused and the user is
///    typing a token, a tappable suggestion list renders below.
/// 2. A trailing `person.crop.circle.badge.plus` button that opens a
///    full contact-picker sheet for multi-select adds.
///
/// Focus state lives in the parent (`ComposeView`) — this view binds
/// into it via `FocusState.Binding` and an opaque `Hashable` value
/// identifying which slot it occupies. That keeps a single
/// `@FocusState` in the parent driving Tab traversal across all three
/// fields without an internal/external focus split.
struct RecipientFieldWithSuggestions<FocusValue: Hashable>: View {
    let label: String
    @Binding var text: String
    let candidates: [RecipientSuggestion]
    let focusBinding: FocusState<FocusValue?>.Binding
    let focusValue: FocusValue
    /// Machine-facing identifier for the text field (e.g. `compose.to`);
    /// the Contacts-picker button derives `<identifier>.picker` from it.
    let identifier: String
    /// Called after the user grants Contacts access from this button, so
    /// the parent can re-snapshot the address book its fields share.
    let onContactsAccessChanged: () -> Void

    @Environment(AppState.self) private var appState
    @State private var showPicker = false
    /// Drives the picker button's affordance alongside `candidates`. Loaded
    /// in `.task`; `.notDetermined` until then, which is also the state that
    /// makes the first tap ask for access.
    @State private var contactsAuthorization: ContactsAuthorizationStatus = .notDetermined
    /// True while the user is away in the privacy pane, so coming back
    /// re-reads authorization and re-snapshots the address book instead of
    /// leaving the button showing the state they just left to change.
    @State private var awaitingSettingsReturn = false
    @Environment(\.scenePhase) private var scenePhase

    private var pickerAffordance: ContactsPickerAffordance {
        ContactsPickerAffordance(
            authorization: contactsAuthorization,
            hasCandidates: !candidates.isEmpty
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                TextField(label, text: $text, axis: .vertical)
                    .autocorrectionDisabled()
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .focused(focusBinding, equals: focusValue)
                    .accessibilityIdentifier(identifier)
                Button {
                    tapPicker()
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .imageScale(.large)
                        .accessibilityLabel(pickerAffordance.hint(for: label))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor.opacity(pickerAffordance.tintOpacity))
                .disabled(!pickerAffordance.isEnabled)
                .help(pickerAffordance.hint(for: label))
                .accessibilityIdentifier("\(identifier).picker")
            }

            if focusBinding.wrappedValue == focusValue {
                let token = RecipientAutocomplete.trailingToken(in: text)
                let suggestions = RecipientAutocomplete.suggestions(
                    for: token,
                    from: candidates
                )
                if !suggestions.isEmpty {
                    suggestionList(suggestions)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            ContactPickerSheet(candidates: candidates) { picked in
                applyPicked(picked)
            }
        }
        .task {
            contactsAuthorization = await appState.contactsStore.authorizationStatus
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, awaitingSettingsReturn else { return }
            awaitingSettingsReturn = false
            Task { @MainActor in
                contactsAuthorization = await appState.contactsStore.authorizationStatus
                onContactsAccessChanged()
            }
        }
    }

    /// One tap, four outcomes. Access is requested from here — not only from
    /// the reader's address menu — so a user who reaches compose first still
    /// has a way to turn Contacts on.
    private func tapPicker() {
        switch pickerAffordance {
        case .pick:
            showPicker = true
        case .requestAccess:
            Task { @MainActor in
                _ = await appState.contactsStore.requestAccess()
                contactsAuthorization = await appState.contactsStore.authorizationStatus
                onContactsAccessChanged()
            }
        case .openSystemSettings, .shareMoreContacts:
            // The user leaves the app to change a system setting, so note
            // that the return trip has to re-read what they chose.
            awaitingSettingsReturn = true
            ContactsPrivacySettings.open()
        case .noCandidates:
            break
        }
    }

    @ViewBuilder
    private func suggestionList(_ suggestions: [RecipientSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    text = RecipientAutocomplete.applying(
                        suggestion: suggestion,
                        toFieldText: text
                    )
                } label: {
                    suggestionRow(suggestion)
                }
                .buttonStyle(.plain)
                if index < suggestions.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: RecipientSuggestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let name = suggestion.name, !name.isEmpty {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(suggestion.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(suggestion.email)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Chains the multi-pick result through `applying` so the first
    /// commit replaces whatever partial token the user might have
    /// typed before opening the sheet, and subsequent picks append.
    /// The picker hands us its selection in display order, so the
    /// recipients land in the field in the same order the user saw
    /// them.
    private func applyPicked(_ picked: [RecipientSuggestion]) {
        guard !picked.isEmpty else { return }
        var working = text
        for suggestion in picked {
            working = RecipientAutocomplete.applying(
                suggestion: suggestion,
                toFieldText: working
            )
        }
        text = working
        focusBinding.wrappedValue = focusValue
    }
}
