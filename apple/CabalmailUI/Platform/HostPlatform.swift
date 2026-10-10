/// The platform a view is being drawn on, as far as the view-level policies
/// care. Only the distinctions that change a rule are modelled.
///
/// Its own file because more than one policy asks the question, and because
/// the targets that compile those policies are not the same set — the watch
/// app takes `ConfirmationDialogPolicy` and nothing else (#1207).
public enum HostPlatform {
    case macOS
    case iOS
    case visionOS
    case watchOS

    /// The platform this build is compiled for.
    public static var current: HostPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(watchOS)
        return .watchOS
        #else
        return .iOS
        #endif
    }

    /// Whether a split view's columns each draw their own navigation bar at
    /// column width — UIKit's split controller, on iPadOS — rather than
    /// sharing one window-wide toolbar (macOS) or an ornament (visionOS). Such
    /// a bar has a fixed occupant budget, and what overflows it is gone, so
    /// the global search field and the title switches move into the column's
    /// content there (`GlobalSearchFieldPlacement`, `FolderSwitchPlacement`).
    /// visionOS answers false, which keeps a future wide layout there on the
    /// shared-bar defaults.
    var columnScopedToolbar: Bool {
        self == .iOS
    }

    /// Whether app windows are composited over passthrough rather than over an
    /// opaque surface. A partly transparent fill has nothing to sit against
    /// there, so a `.secondary` detail disappears (`FilterPillCountStyle`,
    /// #993).
    var drawsOverPassthrough: Bool {
        self == .visionOS
    }

    /// Whether Settings opens with its category list and a category side by
    /// side: the Mac's Settings window and the visionOS Settings tab. iOS
    /// opens on the list alone, on the phone's tab and in the iPad's sheet,
    /// so a category chosen in advance there would skip the list
    /// (`SettingsView.initialSelection`).
    var settingsOpensBothColumns: Bool {
        self == .macOS || self == .visionOS
    }

    /// Whether a new message always opens in a window of its own: the Mac
    /// and visionOS, which never present the compose sheet. iOS decides by
    /// whether its scene can open another window
    /// (`ComposeSurfacePolicy.opensInWindow`).
    var alwaysWindows: Bool {
        self == .macOS || self == .visionOS
    }
}
