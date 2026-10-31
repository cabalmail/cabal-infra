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

    /// Where the open row last sat among the loaded rows, and its shown
    /// neighbours then: what a step goes by once the row has left them. A
    /// re-run of the Unread pill's search drops a message once it is read,
    /// and a window that slides or reloads can drop the open row too, while
    /// the reader still shows it.
    struct Place<ID: Equatable>: Equatable {
        let open: ID
        let index: Int
        let previous: ID?
        let next: ID?
    }

    /// A list's loaded rows in its order, with each row's identity and
    /// whether its filter shows it.
    struct Rows<Row, ID: Equatable> {
        let rows: [Row]
        let id: (Row) -> ID
        let isShown: (Row) -> Bool

        func index(of id: ID) -> Int? {
            rows.firstIndex { self.id($0) == id }
        }
    }

    /// The open row's place in `loaded`, or nil when it isn't loaded.
    static func place<Row, ID>(of open: ID?, in loaded: Rows<Row, ID>) -> Place<ID>? {
        guard let open, let index = loaded.index(of: open) else { return nil }
        let rows = loaded.rows
        return Place(
            open: open,
            index: index,
            previous: target(from: index, .previous, in: rows, isShown: loaded.isShown).map { loaded.id(rows[$0]) },
            next: target(from: index, .next, in: rows, isShown: loaded.isShown).map { loaded.id(rows[$0]) }
        )
    }

    /// The index a step from `open` lands on: the walk from its row while it
    /// is loaded. Once it has left the rows, the walk starts from the gap it
    /// left: just before the neighbour it had below, if that is still
    /// loaded, else just after the one it had above, else where it sat
    /// (`last`). A reload of the Unread pill drops every row read above the
    /// open one too, so the old index alone would put the gap too low. Nil
    /// with no open row, or one that left the rows before its place was
    /// known.
    static func target<Row, ID>(from open: ID?, last: Place<ID>?, _ step: ListStep, in loaded: Rows<Row, ID>) -> Int? {
        guard let open else { return nil }
        let rows = loaded.rows
        if let index = loaded.index(of: open) {
            return target(from: index, step, in: rows, isShown: loaded.isShown)
        }
        guard let last, last.open == open else { return nil }
        let gap = last.next.flatMap(loaded.index(of:))
            ?? last.previous.flatMap(loaded.index(of:)).map { $0 + 1 }
            ?? min(last.index, rows.count)
        let candidates = step == .next
            ? stride(from: gap, to: rows.count, by: 1)
            : stride(from: gap - 1, to: -1, by: -1)
        return candidates.first { loaded.isShown(rows[$0]) }
    }

    static func availability<Row, ID>(
        from open: ID?, last: Place<ID>?, in loaded: Rows<Row, ID>
    ) -> ListStepAvailability {
        ListStepAvailability(
            canPrevious: target(from: open, last: last, .previous, in: loaded) != nil,
            canNext: target(from: open, last: last, .next, in: loaded) != nil
        )
    }
}

/// Keeps the report while the list is out of sight: in a tall window the
/// list is put away behind the open message (`ListOverlay`), which takes
/// it off screen without removing it, and it still answers the steps. The
/// next list in its surface replaces the report, as a fold or a folder
/// change mounts one.
private struct ListStepReporter: ViewModifier {
    @Environment(\.windowCommands) private var commands
    @Environment(\.commandTab) private var tab
    @State private var reporter = UUID()
    let availability: ListStepAvailability

    func body(content: Content) -> some View {
        content
            .onAppear { commands?.report(availability, in: tab, by: reporter) }
            .onChange(of: availability) { _, new in commands?.report(new, in: tab, by: reporter) }
    }
}

extension View {
    /// Publishes which steps this list can take, for the reader's Previous
    /// and Next to dim from (`WindowCommands.listStep(in:)`).
    func reportsListStep(_ availability: ListStepAvailability) -> some View {
        modifier(ListStepReporter(availability: availability))
    }
}
