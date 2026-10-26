import SwiftUI
import CabalmailKit

/// A main window's status banners — offline, failed sends and the app's
/// toast — hung over its section layout from the bottom (#1426,
/// `StatusBannerPlacement`), and kept off the window's fold.
///
/// With no fold they stack in one column at the bottom of the live overlay,
/// as they always have. On a folded iPhone Duo each takes the part of the
/// window `StatusBannerPlacement.slot(in:column:hasControls:)` gives it, so
/// the stack can split in two: the list's half and the reader's in book
/// pose, above and below the crease in laptop pose. The pieces are read
/// through `onFoldPiecesChange(_:)`, so a banner moves only once the fold has
/// settled and two layout passes agree, and with no animation of its own.
///
/// Every banner is a child of one `StatusBannerStack`, keyed by what it is
/// rather than by where it goes, so a fold moving it keeps its state (a
/// failed send's open discard question) and showing or hiding it keeps its
/// slide from the bottom.
struct StatusBannerOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.commandWindowID) private var windowID
    @Environment(\.foldState) private var fold
    let isOffline: Bool
    let failedSends: FailedSendMonitor
    /// The gap under the banners at the window's bottom edge
    /// (`StatusBannerPlacement.bottomInset(in:)`).
    let bottomInset: CGFloat
    /// A toast's trailing action, which the window showing it builds.
    let action: (Toast) -> (() -> Void)?

    /// The overlay's bounds less the window's fold, as last settled.
    @State private var pieces: FoldPieces?

    /// The banners, in the order they stack.
    private enum Banner: Hashable {
        case offline
        case failedSends
        case toast
    }

    var body: some View {
        StatusBannerStack(frames: settledFrames, bottomInset: bottomInset) {
            ForEach(banners, id: \.self) { banner in
                view(for: banner)
                    .environment(\.bannerWidthLimit, settledFrames[slot(of: banner)]?.width)
                    .layoutValue(key: StatusBannerSlotKey.self, value: slot(of: banner))
                    .transition(transition(for: banner))
            }
        }
        .onFoldPiecesChange { pieces = $0 }
    }

    /// The banners showing now.
    private var banners: [Banner] {
        var shown: [Banner] = []
        if isOffline { shown.append(.offline) }
        if !failedSends.visible.isEmpty, appState.client != nil { shown.append(.failedSends) }
        if appState.toast != nil { shown.append(.toast) }
        return shown
    }

    /// The settled frame of each part of a folded window. Empty with no
    /// fold, so the banners follow the live overlay, never a size it had
    /// before a resize or a rotation.
    private var settledFrames: [StatusBannerPlacement.Slot: CGRect] {
        guard fold != .none, let pieces else { return [:] }
        var frames: [StatusBannerPlacement.Slot: CGRect] = [:]
        for slot in StatusBannerPlacement.Slot.allCases {
            frames[slot] = StatusBannerPlacement.frame(of: slot, in: pieces)
        }
        return frames
    }

    private func slot(of banner: Banner) -> StatusBannerPlacement.Slot {
        guard fold != .none, let pieces else { return .whole }
        switch banner {
        // A state, not an event: nothing to tap.
        case .offline:
            return StatusBannerPlacement.slot(in: pieces, column: nil, hasControls: false)
        // Retry, and a close button.
        case .failedSends:
            return StatusBannerPlacement.slot(in: pieces, column: nil, hasControls: true)
        // Every toast here can be closed.
        case .toast:
            return StatusBannerPlacement.slot(
                in: pieces, column: appState.toast?.column(in: windowID), hasControls: true
            )
        }
    }

    /// The events slide in from the bottom; the offline state fades.
    private func transition(for banner: Banner) -> AnyTransition {
        banner == .offline ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    @ViewBuilder
    private func view(for banner: Banner) -> some View {
        switch banner {
        case .offline:
            // No dismissal: it reports a state that is still true, so hiding
            // it would only make the app quieter about being offline (#1426).
            BannerView(
                icon: "wifi.slash",
                text: "Offline — some actions will retry automatically.",
                tint: ColorTokens.warningFg
            )
        case .failedSends:
            if let client = appState.client {
                FailedSendBanner(monitor: failedSends, client: client)
            }
        case .toast:
            if let toast = appState.toast {
                ToastBanner(
                    toast: toast,
                    onAction: action(toast),
                    onDismiss: { appState.toast = nil }
                )
            }
        }
    }
}

/// The part of the window a status banner goes in.
private struct StatusBannerSlotKey: LayoutValueKey {
    static let defaultValue = StatusBannerPlacement.Slot.whole
}

/// Lays the status banners out as bottom-hung, centred stacks, one per
/// slot, 8 pt apart and 12 pt in from the slot's sides: with every banner in
/// `.whole`, the single stack the overlay has always drawn. It fills the
/// space it is offered and takes no touches of its own.
private struct StatusBannerStack: Layout {
    /// The settled frame of each slot of a folded window, in the overlay's
    /// coordinates; a slot with no frame (every slot, with no fold) is the
    /// live bounds.
    var frames: [StatusBannerPlacement.Slot: CGRect]
    var bottomInset: CGFloat
    var spacing: CGFloat = 8
    var sideInset: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The top of what is stacked in each slot so far.
        var stackTop: [StatusBannerPlacement.Slot: CGFloat] = [:]
        // The last banner is the lowest, as in a VStack hung from the bottom.
        for subview in subviews.reversed() {
            let slot = subview[StatusBannerSlotKey.self]
            let area = frames[slot].map { $0.offsetBy(dx: bounds.minX, dy: bounds.minY) } ?? bounds
            let width = max(0, area.width - 2 * sideInset)
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let bottom = stackTop[slot]
                ?? area.maxY - StatusBannerPlacement.bottomInset(of: slot, windowBottomInset: bottomInset)
            subview.place(
                at: CGPoint(x: area.midX, y: bottom),
                anchor: .bottom,
                proposal: ProposedViewSize(width: width, height: size.height)
            )
            stackTop[slot] = bottom - size.height - spacing
        }
    }
}
