import SwiftUI
import CabalmailKit

/// A feed list's answer to Previous and Next (`WindowCommand.step`): it
/// opens the item above or below the open one as a tap does, scrolls to it,
/// reports which steps it can take for the reader's buttons to dim, and asks
/// for the next page as the open item nears the end, since a list put away
/// behind the reader runs none of its rows' own loads. The list's items are
/// its filter's already, so every row is shown; an item read in the Unread
/// pill stays until a reload, after which the step goes by where it sat
/// (`ListStepPolicy.Place`, kept on the model so a fold's move keeps it).
private struct FeedListStepping: ViewModifier {
    let model: FeedItemListViewModel
    /// The item open in the reader.
    let open: RssItem?
    let proxy: ScrollViewProxy
    /// Opens `item` as a tap would.
    let select: (RssItem) -> Void

    /// How near the end of the loaded items the next page is asked for.
    private static let prefetchMargin = 3

    private var loaded: ListStepPolicy.Rows<RssItem, String> {
        ListStepPolicy.Rows(rows: model.items, id: \.id, isShown: { _ in true })
    }

    private var place: ListStepPolicy.Place<String>? {
        ListStepPolicy.place(of: open?.id, in: loaded)
    }

    private var availability: ListStepAvailability {
        ListStepPolicy.availability(from: open?.id, last: model.stepPlace, in: loaded)
    }

    func body(content: Content) -> some View {
        content
            .answersCommands([.step(.previous), .step(.next)]) { command in
                if case .step(let step) = command { take(step) }
            }
            .reportsListStep(availability)
            .onChange(of: place, initial: true) { _, new in
                if let new { model.stepPlace = new }
            }
            .onChange(of: open?.id, initial: true) { _, _ in loadAhead() }
            // A reload cuts the list back to its first page, which can drop
            // an open item from further down: ask for the pages again.
            .onChange(of: model.items.count) { _, _ in loadAhead() }
    }

    private func take(_ step: ListStep) {
        let loaded = loaded
        guard let index = ListStepPolicy.target(from: open?.id, last: model.stepPlace, step, in: loaded) else { return }
        let target = loaded.rows[index]
        select(target)
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target.id, anchor: .center) }
    }

    /// Asks for the next page when the open item is near the end of the
    /// loaded items, or sat beyond them before a reload dropped it.
    private func loadAhead() {
        guard let id = open?.id else { return }
        let lastIndex = model.stepPlace?.open == id ? model.stepPlace?.index : nil
        guard let index = loaded.index(of: id) ?? lastIndex,
              index >= model.items.count - Self.prefetchMargin else { return }
        Task { await model.loadMore() }
    }
}

extension View {
    /// Answers Previous and Next for a feed list (`FeedListStepping`).
    func answersFeedSteps(
        model: FeedItemListViewModel,
        open: RssItem?,
        proxy: ScrollViewProxy,
        select: @escaping (RssItem) -> Void
    ) -> some View {
        modifier(FeedListStepping(model: model, open: open, proxy: proxy, select: select))
    }
}
