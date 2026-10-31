import SwiftUI

extension View {
    /// Folds a view away without removing it: no height, no ink, no taps and
    /// nothing for VoiceOver, while it keeps its identity, its state and
    /// anything it presents (the formatting bar's link alert), which an `if`
    /// would drop. No clipping: the modifier sits on the Mac too, where focus
    /// rings draw outside a control's bounds, and opacity and hit testing
    /// already hide what overflows.
    func collapsed(_ isCollapsed: Bool) -> some View {
        frame(height: isCollapsed ? 0 : nil, alignment: .top)
            .opacity(isCollapsed ? 0 : 1)
            .allowsHitTesting(!isCollapsed)
            .accessibilityHidden(isCollapsed)
    }
}
