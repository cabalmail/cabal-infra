import SwiftUI
import CabalmailKit

/// One labeled recipient field (To / Cc / Bcc) with an inline contacts
/// autocomplete list below it. The list renders only while the field
/// is focused and the user is in the middle of typing a token; tapping
/// a row replaces the trailing token with the formatted recipient and
/// keeps focus in the field so the next address can be typed inline.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: $text, axis: .vertical)
                .autocorrectionDisabled()
                #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .focused(focusBinding, equals: focusValue)

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
}
