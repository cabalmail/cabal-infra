import CabalmailKit

/// The reader's Message menu, the tall bar's menu in a window taller than
/// wide (#1649, the spec's "Message menu ... in every tall window"). In
/// laptop pose it is the one way below the fold to what the message header
/// holds above it, where nothing may be tapped.
///
/// Its rows, from the bar's button outward, and the ones later rows join:
/// Previous and Next, Show Remote Content (the spec's Load Images),
/// Attachments, Addresses, Move to Folder, Display (Reader View, Plain
/// Text) and More (View Source, View Headers, Print). Seven at most,
/// which is what fits between the fold and the bar (about 400 pt). A row
/// shows only when it applies to the open message.
/// Every other placement keeps the overflow menu as it was.
enum ReaderMessageMenuRow: Hashable {
    /// The remote-content toggle, which only an HTML body has.
    case loadImages
    /// A submenu per address in the header.
    case addresses
    case moveToFolder
    /// Reader View and Plain Text, which only an HTML body has.
    case display
    /// View Source, View Headers and Print.
    case more
}

enum ReaderMessageMenuLayout {
    /// What the open message offers the menu.
    struct Content: Equatable {
        var hasHTML: Bool
        var hasPlainAlternative: Bool
        var addressCount: Int
    }

    /// The Display submenu's rows.
    enum DisplayRow: Hashable {
        case readerView
        case plainText
    }

    static func rows(for content: Content) -> [ReaderMessageMenuRow] {
        var rows: [ReaderMessageMenuRow] = []
        if content.hasHTML { rows.append(.loadImages) }
        if content.addressCount > 0 { rows.append(.addresses) }
        rows.append(.moveToFolder)
        if !displayRows(for: content).isEmpty { rows.append(.display) }
        rows.append(.more)
        return rows
    }

    /// Reader View for an HTML body; Plain Text too when the message has
    /// both parts, the only case where the toggle does anything.
    static func displayRows(for content: Content) -> [DisplayRow] {
        guard content.hasHTML else { return [] }
        return content.hasPlainAlternative ? [.readerView, .plainText] : [.readerView]
    }

    /// One address in the Addresses submenu.
    struct AddressEntry: Hashable {
        let address: EmailAddress
        /// Its actions sit in the Addresses submenu itself, under the
        /// address as a heading, rather than in a submenu of their own.
        let actionsInline: Bool
    }

    /// The Addresses submenu's addresses: the user's own first, the ones
    /// they would compose from or revoke, then From, To and Cc in the
    /// header's order. Each address once, however many lines name it (in
    /// Sent, the user's own address is the From line). The first of the
    /// user's own lays its actions out inline, so Revoke is one level down
    /// rather than two; the rest open a submenu each, which keeps the
    /// submenu's height to one address's actions and a row per address.
    static func addresses(
        from: [EmailAddress],
        to: [EmailAddress],
        cc: [EmailAddress],
        isOwned: (EmailAddress) -> Bool
    ) -> [AddressEntry] {
        var seen = Set<String>()
        var own: [EmailAddress] = []
        var others: [EmailAddress] = []
        for address in from + to + cc {
            let key = "\(address.mailbox)@\(address.host)".lowercased()
            guard seen.insert(key).inserted else { continue }
            if isOwned(address) {
                own.append(address)
            } else {
                others.append(address)
            }
        }
        return (own + others).enumerated().map { index, address in
            AddressEntry(address: address, actionsInline: index == 0 && !own.isEmpty)
        }
    }
}
