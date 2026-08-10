import Foundation
import SwiftUI

/// Width policy for the macOS folder sidebar column.
///
/// SwiftUI sizes that column itself, and its own default (144pt, measured on
/// macOS 27) is narrower than the folder rows need: the rows sit inside two
/// nested `DisclosureGroup`s in a sidebar `List`, which puts their content
/// ~60pt in, and the trailing unread badge and row menu take the rest — so a
/// launch renders `I…` and `Arc…` instead of `INBOX` and `Archive`. The column
/// therefore opens at `ideal`, and because that is only a preferred width the
/// native divider still resizes it; `shouldPersist` decides which of the widths
/// the layout reports back is a deliberate drag worth remembering.
enum SidebarColumnWidth {
    /// `@AppStorage`/`UserDefaults` key holding the user's last sidebar width.
    /// Zero (the missing-key default) means "never resized" and resolves to
    /// `ideal`.
    static let storageKey = "cabalmail.layout.sidebarColumnWidth"

    /// Narrow enough to let a user reclaim space for the list and reader,
    /// wide enough that a short folder name still reads.
    static let minimum: CGFloat = 180
    /// Launch width: fits a folder name of typical length plus its badge and
    /// row menu at the disclosure indent above.
    static let ideal: CGFloat = 260
    static let maximum: CGFloat = 420

    /// Slack between the width we asked for and the width the layout reports.
    /// Anything inside it is the column settling rather than a drag; persisting
    /// those instead would let a systematic delta walk the stored width a
    /// little further on every launch. Measured on macOS 26 an unresized
    /// column reports back exactly the width it was given (the split's own 8pt
    /// goes to the divider, outside the measurement), so this is slack against
    /// rounding, not a correction.
    static let persistEpsilon: CGFloat = 4

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum)
    }

    /// The width to open at: the persisted one when the user has set it, else
    /// `ideal`. Values outside the allowed range (a stale store, a width saved
    /// before the bounds changed) are clamped rather than honoured.
    static func resolved(stored: Double) -> CGFloat {
        guard stored > 0 else { return ideal }
        return clamp(CGFloat(stored))
    }

    /// Whether a measured column width is a deliberate resize to remember.
    /// Non-positive widths (the pre-layout measurement) never are.
    static func shouldPersist(measured: CGFloat, stored: Double) -> Bool {
        guard measured > 0 else { return false }
        return abs(clamp(measured) - resolved(stored: stored)) > persistEpsilon
    }
}

#if os(macOS)
/// Opens the sidebar column at `SidebarColumnWidth`'s width and persists the
/// one the user drags to. `min`/`ideal`/`max` rather than a pinned width: the
/// pinned form takes the native divider away, and the divider is how a Mac user
/// expects to resize a sidebar.
private struct SidebarColumnWidthPolicy: ViewModifier {
    @AppStorage(SidebarColumnWidth.storageKey) private var stored: Double = 0
    /// Resolved from the store once, when the modifier is first created.
    /// Frozen for the session deliberately: feeding a freshly persisted width
    /// back in as the preferred one would re-size the column under the drag
    /// that produced it.
    @State private var ideal: CGFloat = SidebarColumnWidth.resolved(
        stored: UserDefaults.standard.double(forKey: SidebarColumnWidth.storageKey)
    )

    func body(content: Content) -> some View {
        // Order matters: the measurement goes *under* the width modifier.
        // Applied the other way round the column-width preference doesn't
        // survive `onGeometryChange` and the sidebar silently reverts to
        // SwiftUI's default width — measured 148pt with the modifier defeated
        // against 268pt with it in effect.
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard SidebarColumnWidth.shouldPersist(measured: width, stored: stored) else { return }
                stored = Double(SidebarColumnWidth.clamp(width))
            }
            .navigationSplitViewColumnWidth(
                min: SidebarColumnWidth.minimum,
                ideal: ideal,
                max: SidebarColumnWidth.maximum
            )
    }
}
#endif

extension View {
    /// macOS: see `SidebarColumnWidthPolicy`. Every other platform sizes its
    /// sidebar elsewhere — iPad-regular collapses this column to zero and
    /// floats the folder panel over the list, compact iPhone makes it the whole
    /// screen — so this passes through.
    @ViewBuilder
    func sidebarColumnWidthPolicy() -> some View {
        #if os(macOS)
        modifier(SidebarColumnWidthPolicy())
        #else
        self
        #endif
    }
}
