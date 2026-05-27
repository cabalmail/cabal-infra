import Foundation
import CabalmailKit

// Helper value types posted by `AppState` to coordinate one-way signals
// between detail / list / compose views. Each carries a monotonic `tick`
// so `.onChange` fires even when the same logical payload (UID, flag,
// folder) recurs after a folder switch or UIDVALIDITY reset.

/// Ephemeral banner message. Promoted out of `AppState` so the nested
/// `Kind` enum stays at a single level of nesting (SwiftLint's cap).
struct Toast: Equatable, Sendable {
    enum Kind: Sendable { case info, success, warning, error }
    let kind: Kind
    let message: String
}

/// Signal payload for a successful dispose action. Carries the folder path
/// and UID so list views in non-matching folders can ignore it, plus a
/// monotonic `tick` so `.onChange` fires even if the same UID value
/// reappears after a folder switch + UIDVALIDITY reset.
struct DisposedEnvelope: Equatable, Sendable {
    let folderPath: String
    let uid: UInt32
    let tick: Int
}

/// Signal payload for a flag change driven from outside the list (currently:
/// the detail view toggling `\Seen`). The list view applies this directly to
/// its in-memory envelope so the row updates without a server round trip.
/// `tick` is monotonic so toggling the same flag back and forth still fires
/// the observer.
struct EnvelopeFlagChange: Equatable, Sendable {
    let folderPath: String
    let uid: UInt32
    let flag: Flag
    let added: Bool
    let tick: Int
}
