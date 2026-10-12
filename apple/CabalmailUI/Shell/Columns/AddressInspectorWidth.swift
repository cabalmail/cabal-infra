import Foundation
import SwiftUI

/// Width policy for the trailing addresses inspector, shared by the
/// `.inspector` modifier that sizes it and by `ToolbarSearchFieldWidth`, which
/// has to know how far it can reach.
///
/// On macOS the inspector also remembers the width it is dragged to. SwiftUI
/// opens it at its preferred width every time it is shown, so a dragged width
/// did not survive so much as closing and reopening the panel, let alone a
/// relaunch; the preferred width is now the remembered one.
enum AddressInspectorWidth {
    /// `@AppStorage`/`UserDefaults` key holding the width the user last left
    /// the inspector at (macOS). Zero (the missing-key default) means "never
    /// resized" and resolves to `ideal`.
    static let storageKey = "cabalmail.layout.addressInspectorWidth"

    static let minimum: CGFloat = 260
    static let ideal: CGFloat = 300
    static let maximum: CGFloat = 420

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum)
    }

    /// The width to open at: the persisted one when the user has set it, else
    /// `ideal`. A stored width outside the range is clamped, as the sidebar's
    /// is (`SidebarColumnWidth.resolved`).
    static func resolved(stored: Double) -> CGFloat {
        guard stored > 0 else { return ideal }
        return clamp(CGFloat(stored))
    }

    /// Whether a measured width is a resize to remember: the sidebar's rule
    /// (`SidebarColumnWidth.shouldPersist`) over the inspector's range.
    static func shouldPersist(measured: CGFloat, stored: Double) -> Bool {
        guard measured > 0 else { return false }
        return abs(clamp(measured) - resolved(stored: stored)) > SidebarColumnWidth.persistEpsilon
    }
}

#if os(macOS)
/// Opens the addresses inspector at the width it was last left at and
/// persists the width it is dragged to.
private struct AddressInspectorWidthPolicy: ViewModifier {
    /// Whether the inspector is showing. Its content lays out while it is
    /// hidden too, and as it closes it reports its preferred width rather than
    /// its own, so only a showing panel's width is remembered.
    let isPresented: Bool
    @AppStorage(AddressInspectorWidth.storageKey) private var stored: Double = 0
    /// The width the next opening asks for. SwiftUI reads it every time the
    /// panel opens, so it follows the store — but only while the panel is
    /// closed, so the preferred width never moves under the drag setting it.
    @State private var ideal: CGFloat = AddressInspectorWidth.resolved(
        stored: UserDefaults.standard.double(forKey: AddressInspectorWidth.storageKey)
    )

    func body(content: Content) -> some View {
        // The measurement goes under the width modifier, for the reason
        // `SidebarColumnWidthPolicy` records.
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard isPresented,
                      AddressInspectorWidth.shouldPersist(measured: width, stored: stored) else { return }
                stored = Double(AddressInspectorWidth.clamp(width))
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                ideal = AddressInspectorWidth.resolved(stored: stored)
            }
            .inspectorColumnWidth(
                min: AddressInspectorWidth.minimum,
                ideal: ideal,
                max: AddressInspectorWidth.maximum
            )
    }
}
#endif

#if !os(visionOS)
extension View {
    /// Sizes the trailing addresses inspector to `AddressInspectorWidth`, so
    /// the panel and the search-field policy that has to account for it read
    /// their widths from the same place; on macOS it also opens the panel at
    /// the width it was last left at (`AddressInspectorWidthPolicy`).
    /// `isPresented` is the inspector's presentation state. (Compiled out on
    /// visionOS, where the inspector APIs are unavailable and the one caller,
    /// `WideMail`, is never built.)
    @ViewBuilder
    func addressInspectorWidth(isPresented: Bool) -> some View {
        #if os(macOS)
        modifier(AddressInspectorWidthPolicy(isPresented: isPresented))
        #else
        inspectorColumnWidth(
            min: AddressInspectorWidth.minimum,
            ideal: AddressInspectorWidth.ideal,
            max: AddressInspectorWidth.maximum
        )
        #endif
    }
}
#endif
