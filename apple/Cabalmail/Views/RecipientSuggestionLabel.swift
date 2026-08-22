import SwiftUI
import CabalmailKit

/// The two-line name/email label a recipient suggestion renders with: the
/// display name on top and the address beneath it in caption grey, or the
/// address alone at name size when the contact has no name.
///
/// `ContactPickerSheet` and `RecipientFieldWithSuggestions` draw the same
/// label for the same `RecipientSuggestion` values — the picker sheet's row
/// and the inline autocomplete row wrap it differently (a selection circle
/// and 12pt spacing vs. a person glyph and 8pt, and different trailing
/// modifiers), but the label between the leading glyph and the spacer is
/// identical in both. Only that label lives here; each row keeps its own
/// glyph, spacing, and `Spacer(minLength: 0)`.
struct RecipientSuggestionLabel: View {
    let suggestion: RecipientSuggestion

    var body: some View {
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
    }
}
