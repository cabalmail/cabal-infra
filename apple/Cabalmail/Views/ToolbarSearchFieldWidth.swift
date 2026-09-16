import SwiftUI

/// Declared width of the trailing addresses inspector, shared by the
/// `.inspector` modifier that sizes it and by `ToolbarSearchFieldWidth`, which
/// has to know how far it can reach.
enum AddressInspectorWidth {
    static let minimum: CGFloat = 260
    static let ideal: CGFloat = 300
    static let maximum: CGFloat = 420
}

/// Width policy for the search field that rides the message-list column's
/// toolbar on wide layouts (`MailRootView.toolbarSearchField`) — macOS and
/// visionOS. iPadOS draws the field in the column instead, because its
/// column-scoped navigation bar can't seat one at all
/// (`GlobalSearchFieldPlacement`); the iOS arms below are what the toolbar
/// host would need if it ever returns there, and are unused meanwhile.
///
/// The field wants `preferred`, which is what makes it right-align cleanly
/// above its column instead of stretching — right up until the toolbar area is
/// narrower than the field. A toolbar item is not clipped to its own column,
/// so the overhang lands *under the neighbouring column*: measured on iPad
/// (when the field still rode the reading pane's toolbar), the magnifier was
/// laid out at x=270.5 against a message list that owned everything up to
/// x=300, the placeholder read "earch all mail", and VoiceOver announced a
/// control that was nowhere on screen. Capping to the measured column is what
/// prevents that.
///
/// The field shares its column's toolbar area with fixed sibling buttons
/// (macOS: Compose, Reload, Addresses; iPad adds the folder-panel toggle and
/// Settings gear on the leading edge), so their footprint is reserved off the
/// column before the field takes its share — otherwise a full-width field
/// plus the siblings would overflow the section and re-crowd the window
/// toolbar the #1047 rework just decongested.
///
/// On macOS the section's leading edge also carries the folder-switch menu
/// (`MessageListView+FolderSwitch`), which stands in for the column's title.
/// Its width is the folder name's, so it can't be a constant here: the menu
/// measures itself and the host passes the result in as `leadingWidth`.
/// Before it was charged, the field was sized as if the section's leading
/// edge were free, and a section that couldn't seat both drew the field over
/// the menu — widening the column didn't help, because the field grew
/// point-for-point with it and its leading edge never moved off the menu.
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
    /// Footprint of the fixed toolbar buttons sharing the column (see the type
    /// comment), at ~44pt of bar per item.
    #if os(iOS)
    static let siblingReserve: CGFloat = 180
    #else
    static let siblingReserve: CGFloat = 140
    #endif
    /// How far the addresses inspector can reach into the list column's
    /// toolbar area on iPad, where it *overlays* the split rather than tiling
    /// it: dragged to its `maximum` (420pt) over a reading pane squeezed to
    /// its floor (`ListColumnWidth.readerFloor`, 360pt), it covers the
    /// trailing 60pt of the list column. macOS tiles its inspector and
    /// shrinks the columns themselves, so there is nothing to subtract.
    static let inspectorOverlap: CGFloat =
        AddressInspectorWidth.maximum - ListColumnWidth.readerFloor

    /// Toolbar width available to the field over a list column of
    /// `columnWidth`, after the fixed siblings take theirs.
    static func availableWidth(columnWidth: CGFloat, reserved: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return 0 }
        return columnWidth - reserved
    }

    /// Width for a *measured* toolbar area of `availableWidth`. A
    /// non-positive area yields no field at all — the fixed siblings already
    /// exceed the column, and any width the field claims would overhang the
    /// neighbouring one. (The pre-layout "not measured yet" case is handled
    /// by `width(columnWidth:inspectorPresented:)`, where measurement
    /// actually happens.)
    static func width(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        // The floor yields to the column rather than reintroducing the
        // overhang: a pane too narrow even for `minimum` gets a field flush to
        // its edge, which is cramped but on screen.
        let floor = min(minimum, availableWidth)
        return min(preferred, max(floor, availableWidth - margin))
    }

    /// How much of a measured leading item (the folder-switch menu, at
    /// `leadingWidth`) is charged against the field over a column of
    /// `columnWidth` whose fixed siblings already take `reserved`.
    ///
    /// The whole width, until charging it would push the field under its
    /// `minimum`. The field never yields past that floor: a folder whose
    /// name is wider than the section can seat beside a usable field gets a
    /// field at its floor over the menu's tail — cramped, but the only way
    /// into search this layout has — rather than no field at all. An
    /// unmeasured (non-positive) leading width charges nothing.
    static func leadingCharge(columnWidth: CGFloat, reserved: CGFloat, leadingWidth: CGFloat) -> CGFloat {
        guard leadingWidth > 0 else { return 0 }
        let roomBesideTheFloor = columnWidth - reserved - minimum - margin
        return min(leadingWidth, max(0, roomBesideTheFloor))
    }

    /// Width for the field over a list column of `columnWidth`, with the
    /// addresses inspector open or closed and a leading toolbar item of
    /// `leadingWidth` (the folder-switch menu; zero when there is none or
    /// it hasn't measured yet). The overlap is charged only on iOS, where
    /// the inspector floats over the columns instead of resizing them (see
    /// `inspectorOverlap`); the leading item is charged per `leadingCharge`.
    ///
    /// A non-positive `columnWidth` is the pre-layout measurement, not a
    /// zero-width pane: it resolves to `preferred` so the field doesn't
    /// launch collapsed and snap wider a frame later.
    static func width(columnWidth: CGFloat, inspectorPresented: Bool, leadingWidth: CGFloat) -> CGFloat {
        guard columnWidth > 0 else { return preferred }
        #if os(iOS)
        let overlap: CGFloat = inspectorPresented ? inspectorOverlap : 0
        #else
        let overlap: CGFloat = 0
        #endif
        let reserved = siblingReserve + overlap
        return width(
            availableWidth: availableWidth(
                columnWidth: columnWidth,
                reserved: reserved + leadingCharge(
                    columnWidth: columnWidth,
                    reserved: reserved,
                    leadingWidth: leadingWidth
                )
            )
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
