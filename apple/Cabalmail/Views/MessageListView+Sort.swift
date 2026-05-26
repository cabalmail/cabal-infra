import SwiftUI
import CabalmailKit

// Sort-menu toolbar item. Pulled into a sibling extension so the primary
// MessageListView body stays under SwiftLint's `type_body_length` cap.
//
// Layout: a `Menu` with a checkmark next to the active field, plus a
// separator and an ascending/descending toggle that flips the direction
// without changing the field. Mirrors the React webmail's "Sort by […]
// ▼ ↓" strip in `react/admin/src/Email/Messages/index.jsx`.
extension MessageListView {
    @ViewBuilder
    var sortMenu: some View {
        Menu {
            if let model {
                @Bindable var bindable = model
                ForEach(SortCriterion.Field.allCases, id: \.self) { field in
                    Button {
                        Task {
                            await bindable.setSort(SortCriterion(
                                field: field,
                                direction: model.sortCriterion.direction
                            ))
                        }
                    } label: {
                        if model.sortCriterion.field == field {
                            Label(sortLabel(for: field), systemImage: "checkmark")
                        } else {
                            Text(sortLabel(for: field))
                        }
                    }
                }
                Divider()
                Button {
                    Task {
                        await bindable.setSort(SortCriterion(
                            field: model.sortCriterion.field,
                            direction: model.sortCriterion.direction == .ascending
                                ? .descending : .ascending
                        ))
                    }
                } label: {
                    Label(
                        model.sortCriterion.direction == .ascending
                            ? "Ascending" : "Descending",
                        systemImage: model.sortCriterion.direction == .ascending
                            ? "arrow.up" : "arrow.down"
                    )
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel("Sort")
        }
        .disabled(model == nil)
    }

    private func sortLabel(for field: SortCriterion.Field) -> String {
        switch field {
        case .dateReceived: return "Date Received"
        case .dateSent:     return "Date Sent"
        case .from:         return "From"
        case .subject:      return "Subject"
        }
    }
}
