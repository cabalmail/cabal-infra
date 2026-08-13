import SwiftUI

/// Declared width of the trailing addresses inspector, shared by the
/// `.inspector` modifier that sizes it and by `ToolbarSearchFieldWidth`, which
/// has to know how much of the detail column it covers.
enum AddressInspectorWidth {
    static let minimum: CGFloat = 260
    static let ideal: CGFloat = 300
    static let maximum: CGFloat = 420
}

/// Width policy for the search field that rides the reading pane's toolbar on
/// wide layouts (`MailRootView.toolbarSearchField`).
///
/// The field was pinned to `preferred`, which is what makes it right-align
/// cleanly above the detail column instead of stretching — right up until the
/// toolbar area is narrower than the field. A toolbar item is not clipped to
/// its own column, so the overhang lands *under the neighbouring column*: on
/// iPad with the addresses inspector open the magnifier was laid out at
/// x=270.5 against a message list that owns everything up to x=300, and the
/// placeholder read "earch all mail". The element stays in the accessibility
/// tree, so VoiceOver announces a control that is nowhere on screen.
enum ToolbarSearchFieldWidth {
    /// The width the field wants: enough for the placeholder and a typical
    /// query without stretching across a wide pane.
    static let preferred: CGFloat = 260
    /// Below this the field is a magnifier and a couple of glyphs — still
    /// tappable and still typable, which is better than a wider field whose
    /// left half is behind another column.
    static let minimum: CGFloat = 88
    /// Room left to the pane's own toolbar margins so the field stops short of
    /// the column edge rather than sitting flush against it.
    static let margin: CGFloat = 24

    /// Toolbar width available over a detail column of `columnWidth`.
    ///
    /// `inspectorWidth` is the addresses panel's footprint when it is showing
    /// and zero when it is not. It is subtracted because on iPad the inspector
    /// *overlays* the detail column: measured live, the column keeps reporting
    /// its full 534pt while the toolbar area it hosts ends where the inspector
    /// begins. Sizing the field against the column alone is what let a 260pt
    /// field sit over a 220pt toolbar.
    static func availableWidth(columnWidth: CGFloat, inspectorWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 0 }
        return columnWidth - inspectorWidth
    }

    /// Width for a toolbar area of `availableWidth`.
    ///
    /// A non-positive width is the pre-layout measurement, not a zero-width
    /// pane: it resolves to `preferred` so the field doesn't launch collapsed
    /// and snap wider a frame later.
    static func width(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return preferred }
        // The floor yields to the column rather than reintroducing the
        // overhang: a pane too narrow even for `minimum` gets a field flush to
        // its edge, which is cramped but on screen.
        let floor = min(minimum, availableWidth)
        return min(preferred, max(floor, availableWidth - margin))
    }

    /// Width for the field over a detail column of `columnWidth`, with the
    /// addresses inspector open or closed.
    ///
    /// The inspector is subtracted only on iOS. There it floats over the detail
    /// column: measured live on iPad, the column keeps reporting its full 534pt
    /// while the toolbar area it hosts ends where the inspector begins. macOS
    /// tiles its inspector and shrinks the column itself, so subtracting there
    /// would charge for the same space twice; the cap against the column still
    /// applies.
    static func width(columnWidth: CGFloat, inspectorPresented: Bool) -> CGFloat {
        #if os(iOS)
        let inspector: CGFloat = inspectorPresented ? AddressInspectorWidth.ideal : 0
        #else
        let inspector: CGFloat = 0
        #endif
        return width(
            availableWidth: availableWidth(columnWidth: columnWidth, inspectorWidth: inspector)
        )
    }
}

#if !os(visionOS)
extension View {
    /// Sizes the trailing addresses inspector to `AddressInspectorWidth`, so
    /// the panel and the search-field policy that has to account for it read
    /// their widths from the same place. (visionOS presents the panel as a
    /// sheet instead and never calls this.)
    func addressInspectorWidth() -> some View {
        inspectorColumnWidth(
            min: AddressInspectorWidth.minimum,
            ideal: AddressInspectorWidth.ideal,
            max: AddressInspectorWidth.maximum
        )
    }
}
#endif
