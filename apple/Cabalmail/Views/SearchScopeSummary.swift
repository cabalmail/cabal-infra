import Foundation

/// Where a search actually looked, as a sentence every search surface can
/// state the same way.
///
/// Issue #1419: cross-folder search covers the subscribed folders except
/// Trash, and the banner reported that as a bare `in 2 folders` — a scope
/// line stacked directly over the match count, so `1 of 1 match` / `in 2
/// folders` read as self-contradictory, and `0 of 0 matches` read as "that
/// word is nowhere in your mail" when it only meant "I did not look where
/// it is". The folders were never unknown: the server names them on every
/// page of a result, and the old label already printed the name when there
/// was exactly one — it discarded them at two or more. Same shape as #1027
/// one step earlier in the flow (two states that render identically and
/// mean opposite things), so it takes the same shape of answer: a plain
/// value, stated once, testable without driving the UI.
struct SearchScopeSummary: Equatable {
    /// Folders the completed search covered, as the server reported them.
    /// Empty only before a search reports or after one fails.
    let foldersSearched: [String]
    /// The filter sheet's "This folder only" toggle.
    let thisFolderOnly: Bool
    /// The surface's own folder. Names a single-folder search whose server
    /// report has not landed; never used to describe a completed one.
    let anchorFolderName: String

    /// How many folders the banner names before it starts counting. Past
    /// this the line costs more width than the names buy.
    static let namedFolderLimit = 3

    init(foldersSearched: [String], thisFolderOnly: Bool, anchorFolderName: String) {
        self.foldersSearched = foldersSearched
        self.thisFolderOnly = thisFolderOnly
        self.anchorFolderName = anchorFolderName
    }

    /// "INBOX", "INBOX and Archive", "INBOX, Archive and Sent",
    /// "INBOX, Archive and 2 more".
    static func phrase(for names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: break
        }
        if names.count <= namedFolderLimit {
            let head = names.dropLast().joined(separator: ", ")
            return "\(head) and \(names[names.count - 1])"
        }
        let head = names.prefix(namedFolderLimit).joined(separator: ", ")
        return "\(head) and \(names.count - namedFolderLimit) more"
    }

    /// The banner's scope line. Leads with the verb so it cannot be read as
    /// a property of the results sitting under it — the whole of the "a
    /// single match cannot be in two folders" complaint.
    var bannerLabel: String {
        if thisFolderOnly {
            return "Searched \(foldersSearched.first ?? anchorFolderName) only"
        }
        guard !foldersSearched.isEmpty else {
            // Reachable only before a search reports (or after one fails),
            // where nothing is known about the scope. The old wording here
            // was "in all folders", which is a claim the app cannot back:
            // an unsubscribed folder is never searched and Trash never is.
            return "Search results"
        }
        return "Searched \(Self.phrase(for: foldersSearched))"
    }

    /// What the empty state adds under "No messages matched X" so the user
    /// can tell an exhausted search from an unasked one, and has somewhere
    /// to go. Nil when the scope is not yet known and there is nothing
    /// honest to say.
    var emptyStateNote: String? {
        if thisFolderOnly {
            let name = foldersSearched.first ?? anchorFolderName
            return "Only \(name) was searched — turn off "
                + "\u{201C}This folder only\u{201D} in Filters to search the rest of your mail."
        }
        guard !foldersSearched.isEmpty else { return nil }
        return "Searched \(Self.phrase(for: foldersSearched)). Folders you are not subscribed to are "
            + "not searched, and Trash never is — subscribe to a folder in Folders to include it."
    }
}
