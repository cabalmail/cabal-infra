import SwiftUI

/// A step from the message or item open in the reader to the row above or
/// below it in its window's list, as the list's Up and Down arrows go
/// (`WindowCommand.step`). The tall window's Message menu sends it; the list
/// in front, which alone knows its order, its filter and its loaded pages,
/// answers it.
public enum ListStep: Hashable, Sendable {
    case previous, next
}

/// Which steps the list in front can take now: a row the filter shows above
/// or below the open one among the loaded rows. At either end, and while
/// the next page has yet to load, the step is unavailable and its button
/// dims (#985: a command never sits live with nothing to act on).
struct ListStepAvailability: Equatable {
    var canPrevious: Bool
    var canNext: Bool

    /// No list, or nothing open in it.
    static let none = ListStepAvailability(canPrevious: false, canNext: false)

    func allows(_ step: ListStep) -> Bool {
        switch step {
        case .previous: canPrevious
        case .next: canNext
        }
    }
}

/// Where a step lands: the nearest row above or below the open one that the
/// list's filter shows, in the list's loaded rows. Walked over every loaded
/// row rather than the filtered ones alone, since in the Unread pill the
/// open message leaves the filtered rows once it is read. Never wraps, and
/// never skips to the next unread.
enum ListStepPolicy {
    /// The index in `rows` a step from `index` lands on, or nil at either
    /// end, or when the open row isn't among the loaded rows.
    static func target<Row>(from index: Int?, _ step: ListStep, in rows: [Row], isShown: (Row) -> Bool) -> Int? {
        guard let index, rows.indices.contains(index) else { return nil }
        let candidates = step == .next
            ? stride(from: index + 1, to: rows.count, by: 1)
            : stride(from: index - 1, to: -1, by: -1)
        return candidates.first { isShown(rows[$0]) }
    }

    static func availability<Row>(from index: Int?, in rows: [Row], isShown: (Row) -> Bool) -> ListStepAvailability {
        ListStepAvailability(
            canPrevious: target(from: index, .previous, in: rows, isShown: isShown) != nil,
            canNext: target(from: index, .next, in: rows, isShown: isShown) != nil
        )
    }
}

private struct ListStepReporter: ViewModifier {
    @Environment(\.windowCommands) private var commands
    @Environment(\.commandTab) private var tab
    @State private var reporter = UUID()
    let availability: ListStepAvailability

    func body(content: Content) -> some View {
        content
            .onAppear { commands?.report(availability, in: tab, by: reporter) }
            .onChange(of: availability) { _, new in commands?.report(new, in: tab, by: reporter) }
            .onDisappear { commands?.withdrawStepReport(in: tab, by: reporter) }
    }
}

extension View {
    /// Publishes which steps this list can take, for the reader's Previous
    /// and Next to dim from (`WindowCommands.listStep(in:)`).
    func reportsListStep(_ availability: ListStepAvailability) -> some View {
        modifier(ListStepReporter(availability: availability))
    }
}
