import SwiftUI

extension View {
    /// Starts this view's content past a book crease's keep-out
    /// (`CreaseClearance`) when the view itself starts at the hinge band or
    /// after it. The compose sheet does in book pose, where it takes the
    /// trailing page a few points past the crease line, and its fields would
    /// otherwise start inside the keep-out (#2262). Reads the fold and the
    /// view's own place in the window, both in window coordinates; adds
    /// nothing with no vertical fold, so on every other device and pose.
    func startsPastCrease() -> some View {
        modifier(CreaseLeadingInset())
    }
}

private struct CreaseLeadingInset: ViewModifier {
    @Environment(\.foldState) private var foldState
    @State private var leadingEdge: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.leading, CreaseClearance.leadingInset(fold: foldState, columnStartingAt: leadingEdge))
            // Measured outside the padding, so the inset can't move what it
            // is measured from.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minX
            } action: { minX in
                leadingEdge = minX
            }
    }
}
