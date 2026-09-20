import SwiftUI

/// The frame of the display's *active* fold in `proxy`'s coordinate space,
/// or nil: iPhone Duo reports its hinge as a reserved region of kind
/// `.division` that is active while the device is partially open (book or
/// laptop pose) and inactive when flat; other hosts have none. Used by
/// `SignedInRootView` to keep the status banners off the hinge (#1648).
///
/// The API is iOS 27.1 (SwiftUICore 8.0.85); the 27.0 SDK and older compile
/// the nil fallback. The compiler version cannot tell 27.0 from 27.1, which
/// is why the guard is on the module version.
func activeFoldRegion(in proxy: GeometryProxy) -> CGRect? {
    #if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)
    if #available(iOS 27.1, *) {
        return proxy.reservedRegions(kind: .division)
            .first { $0.isActive }
            .map(\.frame)
    }
    #endif
    return nil
}
