import SwiftUI

/// The capsule banner primitive shared by the root status overlay
/// (`SignedInRootView`) and the local `toastOverlay` hosts. Dumb on purpose:
/// callers supply the icon / text / tint, and an optional Copy action that,
/// when present, renders a trailing button.
struct BannerView: View {
    let icon: String
    let text: String
    let tint: Color
    /// When non-nil the banner shows a trailing "Copy" button (the
    /// post-creation address banner); nil for plain status banners.
    var onCopy: (() -> Void)?

    init(icon: String, text: String, tint: Color, onCopy: (() -> Void)? = nil) {
        self.icon = icon
        self.text = text
        self.tint = tint
        self.onCopy = onCopy
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let onCopy {
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
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
/// icon and tint. `onCopy` is wired by the host when the toast carries a
/// `copyAddress`.
struct ToastBanner: View {
    let toast: Toast
    var onCopy: (() -> Void)?

    var body: some View {
        BannerView(icon: icon, text: toast.message, tint: tint, onCopy: onCopy)
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
                    ToastBanner(toast: toast, onCopy: copyHandler(for: toast))
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
