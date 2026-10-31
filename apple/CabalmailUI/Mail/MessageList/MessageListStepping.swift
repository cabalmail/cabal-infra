import SwiftUI
import CabalmailKit

/// A message list's answer to Previous and Next (`WindowCommand.step`): it
/// opens the row above or below the open message the way a tap does, scrolls
/// to it, reports which steps it can take for the reader's buttons to dim,
/// and keeps the next page loading as the open message moves, since a list
/// put away behind the reader runs none of its rows' own loads. In Select
/// mode it takes no step: a step there would check a row, not open it.
private struct MessageListStepping: ViewModifier {
    /// Where the open message last sat, for a step once a refresh has
    /// dropped it from the rows (`ListStepPolicy.Place`).
    @State private var lastPlace: ListStepPolicy.Place<MessageRef>?
    let model: MessageListViewModel
    /// The message open in the reader, if this list's.
    let open: MessageRef?
    /// The rows on screen, filtered, for the scroll.
    let visible: [Envelope]
    let proxy: ScrollViewProxy
    /// Opens `envelope` as a tap would, without moving focus.
    let select: (Envelope) -> Void

    /// How near the end of a search's loaded matches the next page is asked
    /// for, as the rows' own prefetch does.
    private static let searchPrefetchMargin = 10

    private var openIndex: Int? {
        open.flatMap { ref in model.envelopes.firstIndex { model.rowRef(for: $0) == ref } }
    }

    private var isShown: (Envelope) -> Bool {
        let filter = model.filterTab
        return { filter.includes($0) }
    }

    private var loaded: ListStepPolicy.Rows<Envelope, MessageRef> {
        let model = model
        return ListStepPolicy.Rows(rows: model.envelopes, id: { model.rowRef(for: $0) }, isShown: isShown)
    }

    private var place: ListStepPolicy.Place<MessageRef>? {
        ListStepPolicy.place(of: open, in: loaded)
    }

    private var availability: ListStepAvailability {
        guard !model.bulkMode else { return .none }
        return ListStepPolicy.availability(from: open, last: lastPlace, in: loaded)
    }

    func body(content: Content) -> some View {
        content
            .answersCommands([.step(.previous), .step(.next)]) { command in
                if case .step(let step) = command { take(step) }
            }
            .reportsListStep(availability)
            .onChange(of: place, initial: true) { _, new in
                if let new { lastPlace = new }
            }
            .onChange(of: open, initial: true) { _, _ in loadAhead() }
    }

    private func take(_ step: ListStep) {
        guard !model.bulkMode else { return }
        let loaded = loaded
        let rows = loaded.rows
        guard let index = ListStepPolicy.target(from: open, last: lastPlace, step, in: loaded) else { return }
        let target = rows[index]
        select(target)
        // The same scroll the arrow keys make: the virtualized list is keyed
        // by slot, the filtered one by `MessageRowIdentity`.
        let virtualize = !model.isSearchActive && visible.count == rows.count
        withAnimation(.easeOut(duration: 0.12)) {
            if virtualize {
                proxy.scrollTo(model.rowSlot(at: Int(model.window?.windowStart ?? 0) + index), anchor: .center)
            } else {
                proxy.scrollTo(MessageRowIdentity.of(target, generations: model.rowGenerations), anchor: .center)
            }
        }
    }

    /// Asks for the rows around the open message: the folder window's pages
    /// near it, or a search's next page near the end of its matches.
    private func loadAhead() {
        guard let index = openIndex else { return }
        if model.search.showsResults {
            if index >= model.envelopes.count - Self.searchPrefetchMargin { model.search.requestMore() }
        } else if let window = model.window {
            window.ensureLoaded(around: Int(window.windowStart) + index)
        }
    }
}

extension View {
    /// Answers Previous and Next for a message list (`MessageListStepping`).
    func answersListSteps(
        model: MessageListViewModel,
        open: MessageRef?,
        visible: [Envelope],
        proxy: ScrollViewProxy,
        select: @escaping (Envelope) -> Void
    ) -> some View {
        modifier(MessageListStepping(model: model, open: open, visible: visible, proxy: proxy, select: select))
    }
}
