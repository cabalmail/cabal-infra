import Foundation

/// Pure value-type helper that inserts a plain-text signature into a compose
/// body.
///
/// Kept out of `ComposeViewModel` so the string-munging is independent of
/// SwiftUI / `@Observable` and can be exercised directly from
/// `CabalmailKitTests`. The signature is always introduced with the RFC 3676
/// signature delimiter `"-- "` (dash-dash-space) on its own line, so
/// downstream mail clients can collapse / strip the signature block the
/// same way every UNIX mail client has since Pine.
public enum SignatureFormatter {
    /// Produces the initial body for a new compose.
    ///
    /// Matches the layout the user expects for each entry point:
    ///
    /// - **New message** (empty base). Result is `\n<delim><signature>`, so
    ///   the cursor lands on the blank line above the signature and the
    ///   user can type above it.
    /// - **Reply / forward** (base leading with `\n\n` for attribution +
    ///   quoted original). Result is `<delim><signature><base>`, placing
    ///   the signature on its own line immediately before the attribution.
    /// - **Any other base** (legacy drafts or tests). Result is
    ///   `<delim><signature>\n<base>`.
    ///
    /// Passing an empty `signature` is a no-op — the original base is
    /// returned unchanged, including the empty-string case.
    public static func seedBody(base: String, signature: String) -> String {
        guard !signature.isEmpty else { return base }
        let signatureBlock = "\n-- \n" + signature
        if base.isEmpty {
            return "\n" + signatureBlock
        }
        if base.hasPrefix("\n\n") {
            return signatureBlock + base
        }
        return signatureBlock + "\n" + base
    }
}
