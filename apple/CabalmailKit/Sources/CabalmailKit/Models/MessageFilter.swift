import Foundation

/// The mail list's filter pill — the three tabs the React webmail shows
/// (`react/admin/src/Email/Messages/index.jsx`). Lives in the kit because
/// `Preferences` stores the pill each folder's list opens on
/// (`mailFolderFilters`); the labels and the envelope predicate stay with
/// the view in the app target.
public enum MessageFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    case flagged

    public var id: String { rawValue }

    /// The pill a mail folder's list opens on until the user picks another.
    public static let defaultForFolders: MessageFilter = .all
}
