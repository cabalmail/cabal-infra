import SwiftUI
@preconcurrency import WebKit

/// A request to page the reader's body a screen up or down: the Page Up and
/// Page Down buttons of a tall window's bar (`ReaderToolbarLayout.tallBar`).
/// The tick advances with every press, so a body sees each press once
/// however often it is laid out, as the print request's tick is.
struct ReaderPageRequest: Equatable, Sendable {
    enum Direction: Sendable {
        case upward, downward
    }

    let direction: Direction
    let tick: Int

    /// The request after this one, in `direction`.
    static func next(after request: ReaderPageRequest?, _ direction: Direction) -> ReaderPageRequest {
        ReaderPageRequest(direction: direction, tick: (request?.tick ?? 0) + 1)
    }
}

/// How far a page moves, for both bodies.
enum ReaderPaging {
    /// The share of the visible height a page moves: the last lines of the
    /// page stay in view, to read on from, as a browser's Page Down leaves
    /// them.
    static let pageFraction: CGFloat = 0.9

    /// Where a plain-text body scrolls to: a page from `offset`, within the
    /// content. A body shorter than its viewport stays at the top.
    static func target(
        from offset: CGFloat, viewport: CGFloat, content: CGFloat, direction: ReaderPageRequest.Direction
    ) -> CGFloat {
        let step = (viewport * pageFraction).rounded()
        let moved = direction == .downward ? offset + step : offset - step
        return min(max(0, moved), max(0, content - viewport))
    }

    /// The script that pages an HTML body, run in the app's own content
    /// world: the page's own JavaScript stays off, and the world shares the
    /// page's document, so it scrolls the window the message is drawn in.
    static func script(_ direction: ReaderPageRequest.Direction) -> String {
        let sign = direction == .downward ? "" : "-"
        return "window.scrollBy({ top: \(sign)Math.round(window.innerHeight * \(pageFraction)), behavior: 'smooth' });"
    }
}

extension HTMLBodyCoordinator {
    /// Pages the web view for a request it has not seen. The first update
    /// only sets the baseline, so a body built after a press (plain text
    /// switched back to HTML) doesn't move on its first layout.
    func handlePageRequest(_ request: ReaderPageRequest?, for webView: WKWebView) {
        let tick = request?.tick ?? 0
        guard let last = lastPageTick else { return lastPageTick = tick }
        guard let request, tick != last else { return }
        lastPageTick = tick
        guard didFinishLoad else { return }
        webView.evaluateJavaScript(ReaderPaging.script(request.direction), in: nil, in: .defaultClient)
    }
}

/// Pages a plain-text body's scroll view on a request, from where it is
/// scrolled: the body reports its geometry here as it moves.
struct PlainBodyPaging: ViewModifier {
    let request: ReaderPageRequest?
    @Binding var position: ScrollPosition
    @State private var geometry = PagedGeometry()

    private struct PagedGeometry: Equatable {
        var offset: CGFloat = 0
        var viewport: CGFloat = 0
        var content: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: PagedGeometry.self) { scroll in
                PagedGeometry(
                    offset: scroll.contentOffset.y,
                    viewport: scroll.containerSize.height,
                    content: scroll.contentSize.height
                )
            } action: { _, newGeometry in
                geometry = newGeometry
            }
            .onChange(of: request) { _, request in
                guard let request else { return }
                let target = ReaderPaging.target(
                    from: geometry.offset, viewport: geometry.viewport,
                    content: geometry.content, direction: request.direction
                )
                withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(y: target) }
            }
    }
}
