import Foundation

/// The mail list's filter pill — the three tabs the React webmail shows
/// (`react/admin/src/Email/Messages/index.jsx`). Lives in the kit because
/// `Preferences` stores the pill each folder's list opens on
/// (`mailFolderFilters`); the labels and the rule for which rows pass stay
/// in the app layer, which also narrows a list to one flag of the user's
/// own, or to any flag, for a visit. That pick is not a case here: these
/// are the values a folder remembers, and the server refuses any other.
public enum MessageFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    case flagged

    public var id: String { rawValue }

    /// The pill a mail folder's list opens on until the user picks another.
    public static let defaultForFolders: MessageFilter = .all

    /// The pills the bar draws. All has none: it is what the list shows with
    /// neither Unread nor Flagged lit.
    public static let pills: [MessageFilter] = [.unread, .flagged]

    /// The filter a tap on `pill` leaves. The pills are toggles: a lit pill
    /// turns off (back to All), an unlit one turns on in place of the other.
    public func toggling(_ pill: MessageFilter) -> MessageFilter {
        self == pill ? .all : pill
    }
}
