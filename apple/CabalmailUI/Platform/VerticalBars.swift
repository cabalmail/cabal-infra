import SwiftUI

extension EnvironmentValues {
    /// Whether the system draws this window's bars in a vertical strip at
    /// one side, as an iPhone built against the iOS 27.1 SDK does on iPhone
    /// Duo's outer display, and on its inner display in a window wider than
    /// tall. Published by `verticalBars()` at a main window's root; false
    /// everywhere else, and on every host and SDK without vertical bars.
    ///
    /// A layout reads this, never the device: the strip comes and goes with
    /// the window's shape, and an app on the left of Split View gets it on
    /// the left (the spec's "read the bar edge, never assume right").
    @Entry var barsAreVertical = false
    /// The edge the strip is on while `barsAreVertical`, as the system
    /// reports it (`toolbarVerticalEdge`); nil otherwise. The strip stays on
    /// the same physical side in a right-to-left language, so the same side
    /// reads as the opposite edge there: take this value, never derive a
    /// side from the layout direction or assume the right. Right-to-left has
    /// not been measured.
    @Entry var verticalBarEdge: HorizontalEdge?
}

extension View {
    /// Publishes `\.barsAreVertical` and `\.verticalBarEdge` to everything
    /// beneath. Applied once, at the root of a main window
    /// (`SignedInRootView`), from the system's own reading of where its bars
    /// go (`toolbarVerticalEdge`, iOS 27.1), behind the same guards as the
    /// fold adapter (`FoldAPI`).
    func verticalBars() -> some View {
        modifier(VerticalBarsModifier())
    }

    /// Asks a short side strip to give up tabs before this screen's own
    /// actions (iOS 27.1 `toolbarVerticalCompressionBehavior(
    /// .prefersToolbarItems)`), for the task screens: the message, compose
    /// and the feed article. Lists keep the system's default, which keeps
    /// the tabs (the Duo spec). Apply beside the screen's `.toolbar`; a no-op
    /// without a strip, and on every other platform and SDK.
    func stripGivesUpTabsFirst() -> some View {
        modifier(StripCompressionModifier())
    }

    /// Keeps this screen's bars horizontal until it has appeared, then lets
    /// the system put them in a strip (iOS 27.1 `toolbarVerticalBehavior`).
    ///
    /// For a sheet on the trailing side, whose bar is a strip down its outer
    /// edge. Presented with the strip already allowed, the sheet laid the
    /// strip out under the status bar, its first item behind the clock, and
    /// kept its title-only items in a horizontal bar that scrolled away with
    /// the form, until the window next changed size (#2259; the iPhone Duo
    /// simulator on iOS 27.1, Xcode 27.2, 2026-10-28). A plain SwiftUI app
    /// does the same, so the fault is the system's. Allowing the strip once
    /// the sheet is up lays it out as a size change does. Remove this once a
    /// release lays the first strip out right. A no-op without a strip, and on
    /// every other platform and SDK.
    func verticalBarsOnceShown() -> some View {
        modifier(VerticalBarsOnceShownModifier())
    }
}

#if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)
private struct VerticalBarsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(VerticalBarsReader())
        } else {
            content
        }
    }
}

private struct StripCompressionModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        } else {
            content
        }
    }
}

private struct VerticalBarsOnceShownModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(VerticalBarsOnceShown())
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarsOnceShown: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .toolbarVerticalBehavior(shown ? .automatic : .disabled)
            .task {
                // The next turn, once the first layout is in.
                await Task.yield()
                shown = true
            }
    }
}

/// A stored property can't be marked `@available`, so the 27.1 environment
/// read lives in a type that is.
@available(iOS 27.1, *)
private struct VerticalBarsReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        content
            .environment(\.barsAreVertical, edge != nil)
            .environment(\.verticalBarEdge, edge)
    }
}
#else
/// No vertical bars on this SDK or platform.
private struct VerticalBarsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

/// No strip to compress on this SDK or platform.
private struct StripCompressionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

/// No strip to hold back on this SDK or platform.
private struct VerticalBarsOnceShownModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}
#endif
