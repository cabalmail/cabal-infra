import SwiftUI

/// The compose sheet's "Open in New Window": moves the draft to a compose
/// window of its own (`ComposeWindowMove`).
///
/// Offered by the router that presents the sheet, through
/// `\.composeWindowOffer`, only where a window can open beside the one the
/// sheet is over (`ComposeSurfacePolicy.offersNewWindow`): an iPad, or an
/// open iPhone Duo, at regular width. Nil everywhere else, the default,
/// hides it, so a compose window, the Mac's and visionOS's included, never
/// shows it. Unavailable until the composer has started, while the draft is
/// being sent or closed, or with the editor down, when there is nothing safe
/// to hand over (`ComposeViewModel.mayHandOff`), and while a dropped item is
/// still being read (`pendingDrops`).
struct ComposeWindowOfferItem: ToolbarContent {
    let model: ComposeViewModel
    @Environment(\.composeWindowOffer) private var offer

    var body: some ToolbarContent {
        if let offer {
            ToolbarItem {
                Button {
                    offer.open(model)
                } label: {
                    // Titled, so the item survives a vertical bar's
                    // overflow, which draws a row from the title (#1787).
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
                .disabled(!model.mayHandOff || model.pendingDrops > 0)
                .accessibilityIdentifier("compose.openInNewWindow")
            }
        }
    }
}

/// What "Open in New Window" does with the sheet's composer. Called from the
/// button's action and synchronous on purpose: the window has to be asked
/// for in the tap's own turn (`ComposeWindowMove.move`). Made only by
/// `moving(with:along:)`, so no caller can put a task between the tap and
/// the request.
struct ComposeWindowOffer {
    let open: @MainActor (ComposeViewModel) -> Void

    private init(open: @escaping @MainActor (ComposeViewModel) -> Void) {
        self.open = open
    }

    /// The offer the router puts on the sheet: `move` moves the composer
    /// along `route`, starting in the tap's own turn.
    @MainActor
    static func moving(with move: ComposeWindowMove, along route: ComposeWindowMove.Route) -> Self {
        Self { model in move.move(model, along: route) }
    }
}

extension EnvironmentValues {
    /// Set by `ComposeRequestRouter` on the compose sheet when it can open a
    /// compose window; nil, the default, hides the action.
    @Entry var composeWindowOffer: ComposeWindowOffer?
}
