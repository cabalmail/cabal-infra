import SwiftUI

extension EnvironmentValues {
    /// Whether this window's sheets sit on its trailing side
    /// (`SheetPlacementPolicy.sitsTrailing`), published by
    /// `windowSheetPlacement()` at the root of a main window and of a compose
    /// window. Sheets inherit it from the window that presents them; their
    /// own size classes describe the sheet, not the window.
    @Entry var sheetsSitTrailing = false
}

/// Where a window's sheets go, by the window's shape (the iPhone Duo spec,
/// "Sheets, compose included, open on the trailing side when the window is
/// wide").
enum SheetPlacementPolicy {
    /// Whether a sheet sits on the window's trailing side, leaving its
    /// leading side in view, rather than where the system puts it.
    ///
    /// Only in a window wider than it is tall that is regular in both size
    /// classes: an iPad in landscape, an open iPhone Duo held wide, flat or
    /// in book pose, where a trailing sheet's bar is a strip down the
    /// hardware edge, clear of the crease. A tall window keeps the system's
    /// placement, centred on an iPad and the Duo's inner display; so does
    /// every compact one, where a sheet takes the width anyway (an iPhone, a
    /// closed Duo, a large iPhone held wide, whose height is compact).
    static func sitsTrailing(windowIsWide: Bool, isRegularWidth: Bool, isRegularHeight: Bool) -> Bool {
        windowIsWide && isRegularWidth && isRegularHeight
    }

    /// Whether one of Cabalmail's own sheets takes only the region below the
    /// fold: in laptop pose, where the Studio measured a half-height sheet
    /// sitting exactly below it, and nothing of Cabalmail's belongs on the
    /// upright half. Compose has its own laptop arrangement and doesn't
    /// take this.
    static func staysBelowFold(_ fold: FoldState) -> Bool {
        if case .horizontal = fold { return true }
        return false
    }
}

extension View {
    /// Publishes where this window's sheets sit (`\.sheetsSitTrailing`).
    /// Apply at a window's root, outside anything that presents a sheet.
    func windowSheetPlacement() -> some View {
        modifier(WindowSheetPlacement())
    }

    /// Places one of Cabalmail's own sheets by the presenting window's
    /// shape: on its trailing side in a wide window, and below the fold in
    /// laptop pose (`SheetPlacementPolicy`). Apply to the sheet's content.
    func windowShapedSheet() -> some View {
        modifier(WindowShapedSheet())
    }
}

private struct WindowSheetPlacement: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var windowIsWide = false

    func body(content: Content) -> some View {
        content
            .environment(\.sheetsSitTrailing, SheetPlacementPolicy.sitsTrailing(
                windowIsWide: windowIsWide,
                isRegularWidth: horizontalSizeClass == .regular,
                isRegularHeight: verticalSizeClass == .regular
            ))
            // The window's shape, read behind it with the keyboard's region
            // ignored, as `SplitShell` reads its split: a docked keyboard
            // would otherwise make a tall window read as wide the moment a
            // field takes focus, and move a sheet while it is typed in.
            .background {
                Color.clear
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.size.width > proxy.size.height
                    } action: { wide in
                        windowIsWide = wide
                    }
                    .ignoresSafeArea(.keyboard)
            }
    }
}

private struct WindowShapedSheet: ViewModifier {
    @Environment(\.sheetsSitTrailing) private var sitsTrailing
    @Environment(\.foldState) private var fold

    func body(content: Content) -> some View {
        let below = SheetPlacementPolicy.staysBelowFold(fold)
        content
            .sheetPlacement(trailing: sitsTrailing)
            .presentationDetents(below ? [.medium] : [.large])
    }
}
