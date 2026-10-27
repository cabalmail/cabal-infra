import SwiftUI

extension EnvironmentValues {
    /// Whether a list column's bar puts its trailing items at the leading end
    /// instead: in book pose, where the bar's trailing end sits within the
    /// crease's keep-out (`CreaseClearance`). Published by `SplitShell` on
    /// its list column; false everywhere else.
    @Entry var listBarItemsLead = false
}

extension ToolbarItemPlacement {
    /// A list bar item that sits at `placement` (the bar's trailing end), or
    /// at the leading end while `leads` (`\.listBarItemsLead`). The leading
    /// placement exists only on iOS; elsewhere the item keeps `placement`.
    static func listBar(_ placement: ToolbarItemPlacement, leads: Bool) -> ToolbarItemPlacement {
        #if os(iOS)
        return leads ? .topBarLeading : placement
        #else
        return placement
        #endif
    }
}
