import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Calls `action` with where the software keyboard will end up, in
    /// screen coordinates (the Duo's window fills its screen, so they are
    /// the window's), or nil as it hides. Apple's guidance for the iPhone
    /// Duo: read these notifications rather than guess the keyboard from the
    /// fold, since a hardware keyboard leaves only a bar. iOS only; nothing
    /// elsewhere.
    func onSoftwareKeyboardChange(_ action: @escaping (CGRect?) -> Void) -> some View {
        #if os(iOS)
        self
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            ) { note in
                action(note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                action(nil)
            }
        #else
        self
        #endif
    }
}
