import SwiftUI
import CabalmailKit

/// A main window's status banners — offline, failed sends and the app's
/// toast — hung over its section layout from the bottom (#1426,
/// `StatusBannerPlacement`), and kept off the window's fold.
///
/// With no fold they stack in one column at the bottom, as they always have.
/// On a folded iPhone Duo each takes the part of the window
/// `StatusBannerPlacement.slot(in:column:hasControls:)` gives it, so the
/// stack can split in two: the list's half and the reader's in book pose,
/// above and below the crease in laptop pose. A banner moves only once the
/// window's fold has settled and two layout passes agree
/// (`onFoldPiecesChange(_:)`), and with no animation of its own.
struct StatusBannerOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.commandWindowID) private var windowID
    let isOffline: Bool
    let failedSends: FailedSendMonitor
    /// The gap under the banners at the window's bottom edge
    /// (`StatusBannerPlacement.bottomInset(in:)`).
    let bottomInset: CGFloat
    /// A toast's trailing action, which the window showing it builds.
    let action: (Toast) -> (() -> Void)?

    /// The overlay's bounds less the window's fold; nil until first read.
    @State private var pieces: FoldPieces?

    /// The banners, in the order they stack.
    private enum Banner: Hashable {
        case offline
        case failedSends
        case toast
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slots, id: \.self) { slot in
                stack(in: slot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// The parts of the window holding a banner, in the order of the
    /// banners they hold.
    private var slots: [StatusBannerPlacement.Slot] {
        var seen: [StatusBannerPlacement.Slot] = []
        for banner in banners where !seen.contains(slot(of: banner)) {
            seen.append(slot(of: banner))
        }
        return seen
    }

    private func slot(of banner: Banner) -> StatusBannerPlacement.Slot {
        guard let pieces else { return .whole }
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

    /// The banners `slot` holds, stacked and hung from its bottom. With no
    /// fold the slot is the whole overlay, so this is the one bottom stack.
    private func stack(in slot: StatusBannerPlacement.Slot) -> some View {
        let frame = pieces.flatMap { StatusBannerPlacement.frame(of: slot, in: $0) }
        return VStack(spacing: 8) {
            ForEach(banners.filter { self.slot(of: $0) == slot }, id: \.self) { banner in
                view(for: banner)
            }
        }
        .padding(.bottom, StatusBannerPlacement.bottomInset(of: slot, windowBottomInset: bottomInset))
        .padding(.horizontal, 12)
        .environment(\.bannerWidthLimit, frame?.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .frame(width: frame?.width, height: frame?.height)
        .offset(x: frame?.minX ?? 0, y: frame?.minY ?? 0)
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .toast:
            if let toast = appState.toast {
                ToastBanner(
                    toast: toast,
                    onAction: action(toast),
                    onDismiss: { appState.toast = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
