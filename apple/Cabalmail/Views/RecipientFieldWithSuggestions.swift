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

    @State private var showPicker = false

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
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .imageScale(.large)
                        .accessibilityLabel("Pick \(label) recipients from Contacts")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(candidates.isEmpty)
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
