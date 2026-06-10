#if os(macOS)
import SwiftUI
import CabalmailKit

/// Compact header grid for the macOS compose window, mirroring
/// Mail.app's From / To / Cc / Bcc / Subject block.
///
/// The compose surface shares one `Form` across platforms, but
/// SwiftUI's default form style on macOS (`.columns`) right-aligns
/// section labels in a gutter sized at roughly half the window width,
/// leaving the upper-left quadrant of the compose window empty. macOS
/// swaps the Form's field sections for this two-column `Grid`: a
/// narrow trailing-aligned label column hugging fields that stretch
/// to the window edge. The editor pane below the header (see
/// `ComposeView.macLayout`) takes all remaining height.
struct ComposeMacHeader: View {
    @Bindable var model: ComposeViewModel
    let candidates: [RecipientSuggestion]
    let focusBinding: FocusState<ComposeView.Field?>.Binding
    let onCreateAddress: () -> Void

    var body: some View {
        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: 8,
            verticalSpacing: 8
        ) {
            GridRow {
                fieldLabel("From:")
                FromPicker(model: model, onCreateAddress: onCreateAddress)
            }
            GridRow {
                fieldLabel("To:")
                recipientField("To", text: $model.toText, focusValue: .to)
            }
            GridRow {
                fieldLabel("Cc:")
                recipientField("Cc", text: $model.ccText, focusValue: .cc)
            }
            GridRow {
                fieldLabel("Bcc:")
                recipientField("Bcc", text: $model.bccText, focusValue: .bcc)
            }
            GridRow {
                fieldLabel("Subject:")
                TextField("Subject", text: $model.subject)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Trailing-aligned secondary label. The Grid sizes the label
    /// column to the widest of these ("Subject:"), so every field
    /// starts the same few points in from the window edge.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func recipientField(
        _ label: String,
        text: Binding<String>,
        focusValue: ComposeView.Field
    ) -> some View {
        RecipientFieldWithSuggestions(
            label: label,
            text: text,
            candidates: candidates,
            focusBinding: focusBinding,
            focusValue: focusValue
        )
    }
}
#endif
