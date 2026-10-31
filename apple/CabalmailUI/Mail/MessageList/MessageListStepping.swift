import SwiftUI
import CabalmailKit

/// A message list's answer to Previous and Next (`WindowCommand.step`): it
/// opens the row above or below the open message the way a tap does, scrolls
/// to it, reports which steps it can take for the reader's buttons to dim,
/// and keeps the next page loading as the open message moves, since a list
/// put away behind the reader runs none of its rows' own loads.
private struct MessageListStepping: ViewModifier {
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

    private var availability: ListStepAvailability {
        ListStepPolicy.availability(from: openIndex, in: model.envelopes, isShown: isShown)
    }

    func body(content: Content) -> some View {
        content
            .answersCommands([.step(.previous), .step(.next)]) { command in
                if case .step(let step) = command { take(step) }
            }
            .reportsListStep(availability)
            .onChange(of: open, initial: true) { _, _ in loadAhead() }
    }

    private func take(_ step: ListStep) {
        let rows = model.envelopes
        guard let index = ListStepPolicy.target(from: openIndex, step, in: rows, isShown: isShown) else { return }
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
