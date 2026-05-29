import SwiftUI
import CabalmailKit

/// Modal sheet that lets the user pick one or more contacts (by email)
/// from their local address book and commit the selection back to a
/// recipient field. Backed by `ContactsStore.allEntries()` — the same
/// snapshot the compose autocomplete already uses, passed in by the
/// caller so we don't re-scan `CNContactStore` per open.
///
/// We render our own list rather than wrapping `CNContactPicker` /
/// `CNContactPickerViewController` for two reasons: `CNContactPicker`
/// on macOS is a popover bound to a view (not a controller) and
/// doesn't slot cleanly into a SwiftUI sheet, and a single SwiftUI
/// surface lets iOS, visionOS, and macOS share one code path with the
/// suggestion-list aesthetic already in place.
struct ContactPickerSheet: View {
    let candidates: [RecipientSuggestion]
    let onCommit: ([RecipientSuggestion]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedIDs: Set<RecipientSuggestion.ID> = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose Contacts")
                #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .searchable(
                    text: $query,
                    placement: .automatic,
                    prompt: "Search name or email"
                )
                .toolbar { toolbarContent }
        }
        // macOS sizes a sheet to its content's ideal height, and a
        // `List` reports a near-zero ideal — so without an explicit
        // frame the content band collapses and neither the rows nor
        // the empty states render, making the picker look like it
        // returns nothing no matter what's typed. Mirrors the frame
        // `MoveToFolderSheet` already carries for the same reason.
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if candidates.isEmpty {
            emptyState
        } else if filteredCandidates.isEmpty {
            noMatchesState
        } else {
            List {
                ForEach(filteredCandidates) { suggestion in
                    Button {
                        toggle(suggestion.id)
                    } label: {
                        row(for: suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        }
    }

    private var filteredCandidates: [RecipientSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        // Reuses the compose autocomplete ranking but with a much higher
        // cap — the picker is the "show me everything that could match"
        // surface, not the inline 5-row hint.
        return RecipientAutocomplete.suggestions(
            for: trimmed,
            from: candidates,
            limit: 500
        )
    }

    @ViewBuilder
    private func row(for suggestion: RecipientSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selectedIDs.contains(suggestion.id) ?
                  "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedIDs.contains(suggestion.id) ?
                                 Color.accentColor : Color.secondary)
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(
            selectedIDs.contains(suggestion.id) ? .isSelected : []
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No contacts available")
                .font(.headline)
            Text("Grant contacts access in Settings to pick recipients from your address book.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Shown when the address book has entries but none match the
    /// active query. Distinct from `emptyState` so the user can tell a
    /// failed search ("no Carr in my contacts") apart from a contacts
    /// book that never loaded ("grant access").
    @ViewBuilder
    private var noMatchesState: some View {
        ContentUnavailableView(
            "No matching contacts",
            systemImage: "magnifyingglass",
            description: Text(
                "No contact matches \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"."
            )
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Add") {
                onCommit(orderedSelection)
                dismiss()
            }
            .disabled(selectedIDs.isEmpty)
        }
    }

    /// Selections returned in the same order as the filtered list, so
    /// the recipient field sees `Add`-tapped contacts appear top-to-
    /// bottom rather than insertion-time chronological.
    private var orderedSelection: [RecipientSuggestion] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    private func toggle(_ id: RecipientSuggestion.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}
