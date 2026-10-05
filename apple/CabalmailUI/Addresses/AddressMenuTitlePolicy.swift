import Foundation
import CabalmailKit

/// How a whole address is drawn in a *menu row* — the compose From menu's
/// per-address buttons and the Default From picker's rows.
///
/// A pure rule rather than an inline `#if` at each call site so it can be
/// tested directly, and so the two menus can't drift apart.
///
/// Everywhere else an address is drawn through `AddressDisplay.wrappable`,
/// whose zero-width spaces give the layout engine a legal break instead of
/// letting it hyphenate an unbreakable token and draw a character the address
/// does not contain (#1547, #1597). A menu row on iOS/iPadOS/visionOS is
/// SwiftUI/UIKit text that really does wrap over three lines, so it needs the
/// treatment and was measured taking it.
///
/// An AppKit menu row is neither: it is a single-line `NSMenuItem` whose menu
/// widens to fit, so there is nothing to wrap — and its title is the string
/// AppKit compares typed characters against for type-to-select. `U+200B`
/// participates in that comparison and sorts below every letter, so the second
/// character typed pushes the buffer past the intended row and the highlight
/// jumps to a *different* address, which Return then commits (#1702: typing
/// `daily` in Settings ▸ Composing ▸ Default From selected another address and
/// wrote it to `default_from_address`). So macOS menu rows draw the raw
/// address: it costs nothing there and type-to-select works again.
enum AddressMenuTitlePolicy {

    /// Whether this platform's menu rows may carry zero-width break
    /// opportunities.
    static func rowMayCarryBreaks(on platform: HostPlatform) -> Bool {
        // macOS is the only one whose menu rows are searched by typed
        // characters — and the only one whose rows never wrap.
        platform != .macOS
    }

    /// The string a menu row draws for `address`. The raw address stays what
    /// `accessibilityLabel` is given, on every platform.
    static func rowTitle(_ address: String, on platform: HostPlatform) -> String {
        rowMayCarryBreaks(on: platform) ? AddressDisplay.wrappable(address) : address
    }
}
