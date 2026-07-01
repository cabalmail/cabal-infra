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

    init(
        icon: String,
        text: String,
        tint: Color,
        actionTitle: String = "Copy",
        actionIcon: String = "doc.on.doc",
        onAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.text = text
        self.tint = tint
        self.actionTitle = actionTitle
        self.actionIcon = actionIcon
        self.onAction = onAction
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Renders a `Toast` value as a `BannerView`, mapping `kind` to the standard
/// icon and tint and the toast's data (copyAddress / resumeCursor) to the
/// trailing button's label. `onAction` is wired by the host to perform it.
struct ToastBanner: View {
    let toast: Toast
    var onAction: (() -> Void)?

    var body: some View {
        BannerView(
            icon: icon,
            text: toast.message,
            tint: tint,
            actionTitle: actionTitle,
            actionIcon: actionIcon,
            onAction: onAction
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
    /// view. Use on surfaces presented modally — compose windows / sheets and
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
                    ToastBanner(toast: toast, onAction: copyHandler(for: toast))
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
