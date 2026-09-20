import SwiftUI

/// Whether the window sits on a display with a fold — an iPhone Duo's inner
/// display — as measured by `MailRootView` from the `.division` reserved
/// region (see `foldCrease`). False on iPad, on a phone that does not fold,
/// and on the outer display of a Duo.
///
/// A plain environment flag rather than a per-view geometry query so the
/// reader can make its bar decision from the same measurement the split
/// used for its columns, and so the two cannot disagree about whether the
/// host folds.
private struct HostHasFoldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hostHasFold: Bool {
        get { self[HostHasFoldKey.self] }
        set { self[HostHasFoldKey.self] = newValue }
    }
}
