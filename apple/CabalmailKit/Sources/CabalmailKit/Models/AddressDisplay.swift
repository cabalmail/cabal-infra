import Foundation

/// How an address is drawn in text the user has to read back: the revoke and
/// suspend confirmations, and on the watch the large-type display, the address
/// list rows and the new-address preview.
///
/// An address is a single unbreakable token, and SwiftUI exposes no
/// hyphenation control — there is no `hyphenationFactor` on `Text` and no
/// paragraph style that reaches it — so when the token has to wrap, the
/// layout engine hyphenates it and draws a hyphen the address does not
/// contain. On a string whose own separators are dots and hyphens that reads
/// as a *different* address (#1547), which matters most on the destructive
/// confirmation whose whole job is letting the user check the target. The one
/// lever left is the string: given a legal break, the engine wraps there and
/// inserts nothing.
public enum AddressDisplay {
    /// `address` with a zero-width space after every character, so the layout
    /// engine can wrap at any point instead of hyphenating.
    ///
    /// A soft hyphen would be the usual way to offer a break, but at a wrap
    /// point it is indistinguishable from the address's own hyphens, so every
    /// *visible* character here stays one the reader should type. Pass the raw
    /// address to `accessibilityLabel` on any surface that takes one; a
    /// `confirmationDialog` title is a plain `String` and takes none.
    public static func wrappable(_ address: String) -> String {
        String(address.flatMap { [$0, breakOpportunity] }.dropLast())
    }

    /// Title of the revoke confirmation, shared by the address list, the
    /// reader's per-address menu and the watch.
    public static func revokeTitle(_ address: String) -> String {
        "Revoke \(wrappable(address))?"
    }

    /// Message of the revoke confirmation. The address list and the reader's
    /// per-address menu carried byte-identical copies of this sentence before
    /// #1547; they read it from here now so a wrapping fix can't reach one and
    /// miss the other.
    public static func revokeMessage(_ address: String) -> String {
        "Mail sent to \(wrappable(address)) will be rejected. This can't be undone."
    }

    /// Title of the suspend confirmation.
    public static func suspendTitle(_ address: String) -> String {
        "Suspend \(wrappable(address))?"
    }

    /// Message of the suspend confirmation.
    public static func suspendMessage(_ address: String) -> String {
        """
        The DNS records for \(wrappable(address)) will be removed and inbound mail \
        will stop being deliverable. The address is kept and can be reinstated \
        at any time.
        """
    }

    private static let breakOpportunity: Character = "\u{200B}"
}
