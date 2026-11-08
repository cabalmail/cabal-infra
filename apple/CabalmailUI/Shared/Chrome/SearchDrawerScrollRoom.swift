import SwiftUI

/// The bottom margin that lets a short list tuck its search drawer away.
///
/// A list's `.searchable` on iOS is a drawer under the navigation bar: a pull
/// reveals it, and pushing the list back up tucks it away again — but UIKit
/// tucks it only when the list can scroll by the drawer's height. A list whose
/// rows don't fill the screen can't, so once a pull revealed the drawer it
/// stayed until the tab was left and re-entered.
///
/// The fix pads the list's scroll content to the tallest viewport it has had.
/// That is the viewport with the drawer tucked away, so with the drawer shown
/// the list can scroll by exactly the drawer's height — enough for a push to
/// tuck it — and with it tucked the list fits and scrolls no further, which
/// keeps the rows from riding up under the filter pills.
enum SearchDrawerScrollRoom {
    /// The margin to add below the rows.
    ///
    /// - Parameters:
    ///   - tallestViewport: the tallest scroll-container height seen at the
    ///     current width.
    ///   - rowsHeight: the content height without any margin this added.
    ///   - insets: the scroll view's top and bottom content insets.
    static func bottomMargin(tallestViewport: CGFloat, rowsHeight: CGFloat, insets: CGFloat) -> CGFloat {
        max(0, (tallestViewport - insets - rowsHeight).rounded())
    }

    /// How long the list's scroll geometry must hold still before the margin
    /// is recomputed (see `SearchDrawerScrollRoomModifier`). The margin is
    /// empty space below the rows, so applying it this late shows nothing.
    static let settleDelay: Duration = .milliseconds(150)
}

/// What the margin is computed from, read off the list's scroll geometry.
private struct SearchDrawerGeometry: Equatable {
    var width: CGFloat
    var viewport: CGFloat
    var content: CGFloat
    var insets: CGFloat
}

/// Internal rather than private so a test can apply it with `onMarginChange`
/// and count what it does; everything else reaches it through
/// `searchDrawerScrollRoom(enabled:)`.
struct SearchDrawerScrollRoomModifier: ViewModifier {
    /// Called with each margin this applies. Nil outside tests.
    var onMarginChange: ((CGFloat) -> Void)?

    @State private var margin: CGFloat = 0
    @State private var tallest: CGFloat = 0
    @State private var tallestWidth: CGFloat = 0
    /// The latest geometry, waiting for the list to stop re-laying out.
    @State private var pending: SearchDrawerGeometry?

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, margin, for: .scrollContent)
            .onScrollGeometryChange(for: SearchDrawerGeometry.self) { geometry in
                SearchDrawerGeometry(
                    width: geometry.containerSize.width,
                    viewport: geometry.containerSize.height,
                    content: geometry.contentSize.height,
                    insets: geometry.contentInsets.top + geometry.contentInsets.bottom
                )
            } action: { _, new in
                // A new width (rotation, a resized iPad window) is a new
                // screen; its tallest viewport starts over.
                if new.width != tallestWidth {
                    tallestWidth = new.width
                    tallest = 0
                }
                tallest = max(tallest, new.viewport)
                pending = new
            }
            // The margin is worked out from settled geometry only. A report
            // can carry a content height laid out with the margin before the
            // last one, and taking the current margin back out of that
            // overshoots: after a back navigation to a short folder list the
            // margin chased its own lag round a six-step cycle forever,
            // pinning the main thread until the watchdog killed the app
            // (`0x8BADF00D`). Once reports stop for `settleDelay` the
            // content includes the margin now applied, so the rows' height
            // comes out exact and one step lands. Each new report restarts
            // the wait (`task(id:)` cancels the sleeping one).
            .task(id: pending) {
                guard let settled = pending else { return }
                do {
                    try await Task.sleep(for: SearchDrawerScrollRoom.settleDelay)
                } catch {
                    return
                }
                let wanted = SearchDrawerScrollRoom.bottomMargin(
                    tallestViewport: tallest, rowsHeight: settled.content - margin, insets: settled.insets
                )
                // The 1 pt dead band keeps a rounding wobble from re-laying
                // the list out again.
                guard abs(wanted - margin) > 1 else { return }
                margin = wanted
                onMarginChange?(wanted)
            }
    }
}

extension View {
    /// Lets a short list tuck its search drawer away again by pushing up
    /// (`SearchDrawerScrollRoom`). Apply it to the `List` itself, and only
    /// where that list carries the `.searchable`; a no-op where the search
    /// field is not a scroll-driven drawer (`searchDrawerFollowsScroll`).
    @ViewBuilder
    func searchDrawerScrollRoom(enabled: Bool = true) -> some View {
        if enabled && HostPlatform.current.searchDrawerFollowsScroll {
            modifier(SearchDrawerScrollRoomModifier(onMarginChange: nil))
        } else {
            self
        }
    }
}
