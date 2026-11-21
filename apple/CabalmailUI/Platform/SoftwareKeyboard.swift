import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Calls `action` with where the software keyboard will end up, or nil as
    /// it hides. The frame is in the window's own coordinates (SwiftUI's
    /// `.global` space, the one the fold's crease is in). The notification
    /// reports it in its screen's, which are the window's only while the
    /// window fills the screen: beside another app in Split View it does
    /// not, so the frame is brought into the window before it is handed on.
    ///
    /// Apple's guidance for the iPhone Duo: read these notifications rather
    /// than guess the keyboard from the fold, since a hardware keyboard
    /// leaves only a bar. iOS only; nothing elsewhere.
    ///
    /// - Parameter center: where the keyboard notifications are read from;
    ///   the default center in the app.
    func onSoftwareKeyboardChange(
        from center: NotificationCenter = .default,
        _ action: @escaping (CGRect?) -> Void
    ) -> some View {
        modifier(SoftwareKeyboardReader(center: center, action: action))
    }
}

#if os(iOS)
/// A keyboard notification's end frame, brought from the screen that posted
/// it into a window.
enum SoftwareKeyboardFrame {
    /// - Parameters:
    ///   - note: a keyboard notification. Its object is the screen its
    ///     frames are in, which is the one to convert from: with more than
    ///     one screen it need not be the window's.
    ///   - window: the window of the view that asked.
    /// - Returns: the end frame in `window`'s coordinates, or nil when the
    ///   notification carries none. A notification without its screen, or a
    ///   view not in a window yet, leaves nothing to convert between, and
    ///   the frame comes back as reported.
    @MainActor
    static func end(of note: Notification, in window: UIWindow?) -> CGRect? {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return nil }
        guard let screen = note.object as? UIScreen, let window else { return frame }
        return screen.coordinateSpace.convert(frame, to: window)
    }
}

private struct SoftwareKeyboardReader: ViewModifier {
    let center: NotificationCenter
    let action: (CGRect?) -> Void
    @State private var anchor = SoftwareKeyboardAnchor()

    func body(content: Content) -> some View {
        content
            .background {
                SoftwareKeyboardAnchorView(anchor: anchor)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onReceive(center.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                // The window is read as each frame arrives, never kept: the
                // view can move to another window between two of them.
                action(SoftwareKeyboardFrame.end(of: note, in: anchor.view?.window))
            }
            .onReceive(center.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                action(nil)
            }
    }
}

/// The view a `SoftwareKeyboardReader` finds its window through.
@MainActor
private final class SoftwareKeyboardAnchor {
    weak var view: UIView?
}

/// A clear view behind the content that draws nothing and takes no touches:
/// it is there only so the reader can ask which window it is in.
private struct SoftwareKeyboardAnchorView: UIViewRepresentable {
    let anchor: SoftwareKeyboardAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        anchor.view = uiView
    }
}
#else
/// No software keyboard to read on this platform.
private struct SoftwareKeyboardReader: ViewModifier {
    let center: NotificationCenter
    let action: (CGRect?) -> Void

    func body(content: Content) -> some View {
        content
    }
}
#endif
