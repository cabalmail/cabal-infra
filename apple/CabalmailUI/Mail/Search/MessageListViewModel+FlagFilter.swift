import SwiftUI
import CabalmailKit

/// Which of a list's rows pass its filter: the pill that is lit, and under
/// Flagged the flag picked from its menu, if one was.
///
/// A pill is a server search, and this is the same rule over the rows in
/// hand: the folder's own until the search answers, and the answer's
/// afterwards, so a row whose flag is taken off leaves the list at once.
/// Every reader of the rows asks it (the list, Select All, Previous and
/// Next), and none asks the pill alone, since Flagged over a pick means the
/// picked flag and not the built-in one.
struct MessageListNarrowing: Equatable {
    var tab: MessageFilter = .all
    /// The flag picked from the Flagged pill's menu; nil for the pill's own
    /// filter.
    var flag: FlagCriterion?

    /// False for All, where every row passes.
    var narrows: Bool { tab != .all || flag != nil }

    /// The rows of `envelopes` the list draws.
    func shown(_ envelopes: [Envelope]) -> [Envelope] {
        narrows ? envelopes.filter(includes) : envelopes
    }

    func includes(_ envelope: Envelope) -> Bool {
        if let flag { return flag.matches(envelope.flags) }
        switch tab {
        case .all:     return true
        case .unread:  return !envelope.flags.contains(.seen)
        case .flagged: return envelope.flags.contains(.flagged)
        }
    }
}

// The Flagged pill's menu on a folder list (`FlagFilterMenuPolicy`): what
// each row does, what the pill then shows, and where the pick is kept.
@MainActor
extension MessageListViewModel {
    /// The flag the list is narrowed to for this visit, picked from the
    /// Flagged pill's menu: a flag of the user's own, or any flag. Nil
    /// under the pills' own filters, the built-in flag's included.
    ///
    /// It lives in the search's filters, so every run and re-run sends it
    /// and whatever replaces the filters ends it. It is never recorded for
    /// the folder: only the window holds it (`flagVisit`), for the folder's
    /// next list.
    var flagPick: FlagCriterion? { filterTab == .flagged ? search.filters.flag : nil }

    /// What the rows on screen are narrowed to.
    var narrowing: MessageListNarrowing { MessageListNarrowing(tab: filterTab, flag: flagPick) }

    /// What the Flagged pill is lit on, for its menu's checkmark: nothing,
    /// the built-in flag, or the pick.
    var flagFilterCurrent: FlagCriterion? {
        filterTab == .flagged ? flagPick ?? .slot(FlagPalette.systemSlot) : nil
    }

    /// The picked flag's number: what the server counted, kept in step with
    /// the rows as they leave (`MailSearchSession.matchCount`). Nil with no
    /// pick, and until the pick's search answers.
    var flagPickCount: Int? {
        guard flagPick != nil else { return nil }
        return search.matchCount(stillMatching: search.rows.filter(narrowing.includes).count)
    }

    /// The Flagged pill as a menu, or nil while the bar draws the plain
    /// toggle (no flag of the user's own, and no pick).
    var flagFilterPill: FlagFilterPillModel? {
        FlagFilterMenuPolicy.pill(
            palette: flagPalette, current: flagFilterCurrent, builtInCount: flagged, pickCount: flagPickCount
        )
    }

    /// A row of the Flagged pill's menu.
    ///
    /// The built-in flag's row is the Flagged filter the folder has always
    /// had, and is recorded for the folder as a tap on the plain pill is. A
    /// flag of the user's own and Any flag are picks: they last for the
    /// visit and record nothing, so the folder reopens on the pill it had.
    /// Clear filter is All, recorded as every route to All is.
    ///
    /// The row already in force does nothing while its own search has
    /// answered or is on its way. Once that search has failed the same row
    /// sends it again: nothing else would, since a refresh re-runs only a
    /// search that answered, and an earlier pill's rows may still be the
    /// ones on screen.
    func chooseFlagFilter(_ choice: FlagFilterChoice) async {
        guard let criterion = FlagFilterMenuPolicy.criterion(for: choice) else {
            await selectFilter(.all)
            return
        }
        guard criterion.isSystemFlag else {
            await narrow(to: criterion)
            return
        }
        let inForce = filterTab == .flagged && flagPick == nil
        guard !(inForce && searchHasAnsweredOrIsOut) else { return }
        if let folder { preferences.setMailFolderFilter(.flagged, for: folder.path) }
        await applyFilter(.flagged)
    }

    /// Narrows the list to a picked flag without recording it: the pill
    /// lights (`filterTab`'s setter records only a move to All), and the
    /// folder-scoped search for the flag replaces whatever was running.
    func narrow(to pick: FlagCriterion) async {
        // Only what the server can be asked for: a slot of the palette, or
        // any flag. Anything else would send a search with no criterion.
        guard pick == .any || pick.keywordSlot != nil else { return }
        guard !(flagPick == pick && searchHasAnsweredOrIsOut) else { return }
        filterTab = .flagged
        searchQuery = ""
        search.filters = MessageSearchFilters(flag: pick, thisFolderOnly: true)
        holdFlagPick()
        await runSearch(resetFilterTab: false)
    }

    /// Tells the window what this folder's list is now picked on, for the
    /// folder's next list. Called wherever the filters are replaced.
    func holdFlagPick() {
        flagVisit?.record(flagPick)
    }

    /// The search for the filters now in force has answered, or is out.
    /// Not `isSearchActive`: that stays true for the rows of the search
    /// before, which a failed one leaves on screen.
    private var searchHasAnsweredOrIsOut: Bool { search.matchTotal != nil || search.isLoading }

    /// What the list says under a pick that nothing in the folder carries,
    /// given how many rows it is showing; nil while there is a row, an
    /// answer or a page still to come, or an error on screen.
    func flagPickEmptyState(visibleRowCount: Int) -> FlagPickEmptyState? {
        FlagPickEmptyState(
            pick: flagPick,
            name: FlagFilterMenuPolicy.name(of: flagPick, palette: flagPalette),
            folderName: folder?.name ?? "",
            // The pick's own answer says none is left (so not while a new
            // pick's search is out, and steadily through a refresh of this
            // one), no page is still to come, and no error is showing.
            isSettled: flagPickCount == 0 && search.nextCursor == nil && errorMessage == nil,
            visibleRowCount: visibleRowCount
        )
    }
}

/// What a folder's list says when it is narrowed to a picked flag and no
/// message there carries it. A menu row shows no number, so an empty answer
/// is an ordinary result of trying a flag, and a blank list would not say
/// whether anything was looked for.
struct FlagPickEmptyState: Equatable {
    let title: String
    let message: String

    /// - Parameter isSettled: the pick's search has answered and none of
    ///   its matches is left or still to come. Before that an empty list is
    ///   not an answer.
    init?(pick: FlagCriterion?, name: String, folderName: String, isSettled: Bool, visibleRowCount: Int) {
        guard let pick, isSettled, visibleRowCount == 0 else { return nil }
        if pick == .any {
            title = "No flagged messages"
            message = "Nothing in \(folderName) carries a flag."
        } else {
            title = "No messages marked \(name)"
            message = "Nothing in \(folderName) carries this flag."
        }
    }
}

extension MessageListView {
    /// Overlaid on the list; empty unless a picked flag found nothing.
    @ViewBuilder
    func flagPickPlaceholder(model: MessageListViewModel, visibleRowCount: Int) -> some View {
        if let empty = model.flagPickEmptyState(visibleRowCount: visibleRowCount) {
            ContentUnavailableView(empty.title, systemImage: "flag", description: Text(empty.message))
        }
    }
}
