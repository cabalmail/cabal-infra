import Foundation

/// The folder STATUS the loaded window is known to line up with: when the
/// counts last agreed with the rows, the server's message total (moved since
/// by this client's own removals, `adjustTotalMessages`) and its UIDNEXT.
///
/// Every message that enters a folder takes a UID at or above UIDNEXT, so
/// between two STATUS replies `uidNext - anchor.uidNext` bounds the arrivals
/// and `arrivals - (total - anchor.total)` the removals made somewhere other
/// than this list. That is what lets a refresh tell an ordinary arrival at
/// the top of the list from a change that has moved the server's positions
/// under the loaded rows (#1817, #1818).
///
/// One change it can't see: another IMAP client flagging a message
/// `\Deleted` (or clearing the flag) without an expunge. The list's pages
/// leave such messages out while STATUS still counts them, so the window can
/// sit one row off until the expunge lowers the count.
struct WindowAnchor: Equatable {
    var total: UInt32
    var uidNext: UInt32

    /// Arrivals and removals elsewhere since the anchor, or nil when the
    /// reply can't follow from it (UIDNEXT went backwards, or more messages
    /// than UIDs arrived), in which case nothing proves where the rows sit.
    func change(toTotal newTotal: UInt32, uidNext newUidNext: UInt32) -> (arrivals: Int, removals: Int)? {
        guard newUidNext >= uidNext else { return nil }
        let arrivals = Int(newUidNext - uidNext)
        let removals = arrivals - (Int(newTotal) - Int(total))
        return removals >= 0 ? (arrivals, removals) : nil
    }
}

/// A STATUS reply as the reconciliation reads it.
struct WindowReading {
    let total: UInt32
    let uidNext: UInt32
    let askedAt: ContinuousClock.Instant
}

/// What a refresh does with the loaded window.
enum WindowPlan: Equatable {
    /// Fold in the top page, as refreshes always have.
    case topPage
    /// The window is trimmed and nothing moved: take the counts only.
    case countsOnly
    /// Re-read these server positions and make them the window.
    case reread(Range<Int>)
}

/// Decides how a refresh treats the loaded window, from where the window
/// sits and what a trusted STATUS reading says changed since its anchor.
/// A value built afresh from the window's state each time it is asked.
struct WindowPlanner {
    /// Rows one server page holds at most (helper.py clamps a page to 250).
    static let windowReadLimit = 250

    /// Rows loaded in the window.
    let loadedCount: Int
    /// The absolute position of the window's first row.
    let windowStart: UInt32
    /// The window no longer starts at the folder's top.
    let hasTrimmedFront: Bool
    /// What the window last lined up with; nil when nothing proves it.
    let anchor: WindowAnchor?
    /// The lowest and highest positions the list is rendering, if any.
    let firstVisibleRow: Int?
    let lastVisibleRow: Int?
    /// The top page's size, and the most rows the window keeps.
    let pageSize: UInt32
    let windowCap: Int

    /// The common cases cost what they always have: a quiet folder, and new
    /// mail arriving above an untrimmed window, both take the top page (the
    /// arrivals are then checked against it in `settleAnchor`). Anything the
    /// counts can't explain -- a removal made elsewhere, or any change at all
    /// under a trimmed window -- means the server's positions have moved
    /// under the rows, so the rows are read again (`rereadWindow`).
    func planWindow(_ reading: WindowReading?) -> WindowPlan {
        // An untrustworthy reply changes nothing about the window.
        guard let reading else { return hasTrimmedFront ? .countsOnly : .topPage }
        // An emptied folder is the top page's to settle (#939).
        if reading.total == 0 { return .topPage }
        let count = loadedCount
        guard let anchor,
              let change = anchor.change(toTotal: reading.total, uidNext: reading.uidNext)
        else {
            // Nothing proves where the rows sit. A small window, or a folder
            // the top page covers, is settled by the top page itself (its
            // prune licence anchors the window); anything larger is read
            // again in one page, the same round trips as the top page.
            if hasTrimmedFront { return .reread(centredWindowRange(total: reading.total)) }
            if count <= Int(pageSize) || reading.total <= pageSize { return .topPage }
            return .reread(0..<min(Int(reading.total), count, Self.windowReadLimit))
        }
        if change.arrivals == 0 && change.removals == 0 {
            return hasTrimmedFront ? .countsOnly : .topPage
        }
        if hasTrimmedFront { return .reread(centredWindowRange(total: reading.total)) }
        // Pure arrivals usually land in the top page; so does every row of a
        // window that can't have been pushed past it, which the top page's
        // own prune then settles.
        if change.removals == 0 || count + change.arrivals <= Int(pageSize) { return .topPage }
        return .reread(coveringWindowRange(arrivals: change.arrivals, total: reading.total))
    }

    /// From the top through every position an untrimmed window's rows can
    /// have reached (each arrival pushes them down one), when that fits the
    /// window's cap; a read centred on the viewport otherwise.
    func coveringWindowRange(arrivals: Int, total: UInt32) -> Range<Int> {
        let reach = min(Int(total), loadedCount + arrivals)
        guard reach > windowCap else { return 0..<reach }
        return centredWindowRange(total: total)
    }

    /// One page of positions centred on what the list is showing (the middle
    /// of the window when no row has reported in yet).
    func centredWindowRange(total: UInt32) -> Range<Int> {
        let total = Int(total)
        let centre: Int
        if let first = firstVisibleRow, let last = lastVisibleRow {
            centre = (first + last) / 2
        } else {
            centre = Int(windowStart) + loadedCount / 2
        }
        let half = Self.windowReadLimit / 2
        let lower = max(0, min(centre - half, total - Self.windowReadLimit))
        return lower..<max(lower, min(total, lower + Self.windowReadLimit))
    }
}
