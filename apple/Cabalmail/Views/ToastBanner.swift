import SwiftUI

/// The capsule banner primitive shared by the root status overlay
/// (`SignedInRootView`) and the local `toastOverlay` hosts. Dumb on purpose:
/// callers supply the icon / text / tint, and an optional Copy action that,
/// when present, renders a trailing button.
struct BannerView: View {
    let icon: String
    let text: String
    let tint: Color
    /// Trailing-button label (e.g. "Copy", "Resume"); defaults to the original
    /// address-copy banner's "Copy".
    var actionTitle: String
    /// Trailing-button SF Symbol, paired with `actionTitle`.
    var actionIcon: String
    /// When non-nil the banner shows a trailing action button (the
    /// post-creation address banner's Copy, the cross-client Resume); nil for
    /// plain status banners.
    var onAction: (() -> Void)?
    /// When non-nil the banner can be got rid of: a close button and a swipe
    /// in any direction. Nil for a banner that reports a state rather than an
    /// event (the offline banner), where dismissing would only hide something
    /// still true.
    var onDismiss: (() -> Void)?

    init(
        icon: String,
        text: String,
        tint: Color,
        actionTitle: String = "Copy",
        actionIcon: String = "doc.on.doc",
        onAction: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.text = text
        self.tint = tint
        self.actionTitle = actionTitle
        self.actionIcon = actionIcon
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let onAction {
                Button(action: onAction) {
                    Label(actionTitle, systemImage: actionIcon)
                        .font(.footnote.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .tint(tint)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("banner.dismiss")
                .padding(.leading, ToastDismissal.closeButtonLeadingGap(hasAction: onAction != nil))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
        // Cap the banner at ~70% of the container width so it clears the
        // toolbar/action buttons it would otherwise overlap. Text wraps within
        // this width (no lineLimit) and the capsule grows vertically to fit.
        .containerRelativeFrame(.horizontal) { width, _ in width * 0.7 }
        // A plain `.gesture` rather than a high-priority one, so the trailing
        // action and the close button keep winning their own taps.
        .gesture(dismissSwipe)
    }

    private var dismissSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                guard let onDismiss,
                      ToastDismissal.dismisses(translation: value.translation) else { return }
                onDismiss()
            }
    }
}

/// Renders a `Toast` value as a `BannerView`, mapping `kind` to the standard
/// icon and tint and the toast's data (copyAddress / resumeCursor) to the
/// trailing button's label. `onAction` is wired by the host to perform it.
struct ToastBanner: View {
    let toast: Toast
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        BannerView(
            icon: icon,
            text: toast.message,
            tint: tint,
            actionTitle: actionTitle,
            actionIcon: actionIcon,
            onAction: onAction,
            onDismiss: onDismiss
        )
    }

    private var actionTitle: String {
        toast.resumeCursor != nil ? "Resume" : "Copy"
    }

    private var actionIcon: String {
        toast.resumeCursor != nil ? "arrow.right.circle" : "doc.on.doc"
    }

    private var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "tray.and.arrow.up.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: return .green
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

extension View {
    /// Hosts a transient, auto-dismissing toast anchored to the top of this
    /// view. Unlike the root status banners (#1426) this host stays at the
    /// top: its callers are the compose and settings sheets, whose bottom edge
    /// is where the keyboard comes up. Use on surfaces presented modally — compose windows / sheets and
    /// the settings sheet — where the root `AppState.toast` overlay would be
    /// hidden behind the presented content. A toast carrying a `copyAddress`
    /// renders a Copy button that copies the address and swaps in the shared
    /// "successfully copied" confirmation.
    func toastOverlay(
        _ toast: Binding<Toast?>,
        duration: TimeInterval = 7
    ) -> some View {
        modifier(ToastOverlayModifier(toast: toast, duration: duration))
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @Binding var toast: Toast?
    let duration: TimeInterval

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    ToastBanner(
                        toast: toast,
                        onAction: copyHandler(for: toast),
                        onDismiss: { self.toast = nil }
                    )
                        .padding(.top, 6)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: toast)
            // `task(id:)` restarts whenever the toast value changes: a new
            // toast cancels the prior timer (the catch returns without
            // clearing the replacement), and after `duration` the current
            // toast clears itself.
            .task(id: toast) {
                guard toast != nil else { return }
                do {
                    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                } catch {
                    return
                }
                toast = nil
            }
    }

    private func copyHandler(for toast: Toast) -> (() -> Void)? {
        guard let address = toast.copyAddress else { return nil }
        return {
            copyToPasteboard(address)
            self.toast = .addressCopied(address)
        }
    }
}
