import SwiftUI

/// `confirmationDialog`, except that it presents as an alert while a fold
/// runs top to bottom through the window (`ConfirmationDialogPolicy
/// .presentsAsAlert`): on an iPhone Duo in book pose the dialog's popover
/// lands within 44 pt of the crease, and an alert stays clear of it. Every
/// dialog in the shared app layer goes through it, so a new one cannot
/// bypass the fold (`ConfirmationPromptTests`).
///
/// The overloads take SwiftUI's own argument shapes, so a call site changes
/// one word. The actions and the message are the same views in either
/// style, which is why the back-out button still asks
/// `ConfirmationDialogPolicy.backOutRole` for its role: an alert draws every
/// button, and the role is what the dialog needs.
///
/// A question keeps the style it opened with. Folding or unfolding while it
/// is up does not dismiss it and present it again in the other style; the
/// next question follows the fold.
extension View {
    func confirmationPrompt<A: View, M: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) -> some View {
        modifier(ConfirmationPrompt(
            title: Text(titleKey), titleVisibility: titleVisibility, isPresented: isPresented,
            data: (), actions: { _ in actions() }, message: { _ in message() }
        ))
    }

    @_disfavoredOverload
    func confirmationPrompt<S: StringProtocol, A: View, M: View>(
        _ title: S,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) -> some View {
        modifier(ConfirmationPrompt(
            title: Text(title), titleVisibility: titleVisibility, isPresented: isPresented,
            data: (), actions: { _ in actions() }, message: { _ in message() }
        ))
    }

    func confirmationPrompt<T, A: View, M: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: @escaping (T) -> M
    ) -> some View {
        modifier(ConfirmationPrompt(
            title: Text(titleKey), titleVisibility: titleVisibility, isPresented: isPresented,
            data: data, actions: actions, message: message
        ))
    }

    @_disfavoredOverload
    func confirmationPrompt<S: StringProtocol, T, A: View, M: View>(
        _ title: S,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: @escaping (T) -> M
    ) -> some View {
        modifier(ConfirmationPrompt(
            title: Text(title), titleVisibility: titleVisibility, isPresented: isPresented,
            data: data, actions: actions, message: message
        ))
    }
}

/// Both presentations hang on the view at once, each shown only while the
/// question is up in its style, so neither appears or disappears with the
/// fold and the view's identity never changes.
private struct ConfirmationPrompt<T, A: View, M: View>: ViewModifier {
    let title: Text
    let titleVisibility: Visibility
    @Binding var isPresented: Bool
    let data: T?
    let actions: (T) -> A
    let message: (T) -> M

    @Environment(\.foldState) private var fold
    /// The style the showing question opened with; nil while none is up.
    @State private var openedAsAlert: Bool?

    private var asAlert: Bool {
        openedAsAlert ?? ConfirmationDialogPolicy.presentsAsAlert(on: .current, foldIsVertical: foldIsVertical)
    }

    private var foldIsVertical: Bool {
        if case .vertical = fold { return true }
        return false
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title, isPresented: shown(asAlert: false), titleVisibility: titleVisibility,
                presenting: data, actions: actions, message: message
            )
            .alert(title, isPresented: shown(asAlert: true), presenting: data, actions: actions, message: message)
            .onChange(of: isPresented, initial: true) { _, showing in
                openedAsAlert = showing ? asAlert : nil
            }
    }

    /// The caller's binding as one style sees it: up only while the question
    /// is up in that style, and dismissing it only from there.
    private func shown(asAlert style: Bool) -> Binding<Bool> {
        Binding(
            get: { isPresented && asAlert == style },
            set: { showing in
                if !showing, asAlert == style { isPresented = false }
            }
        )
    }
}
