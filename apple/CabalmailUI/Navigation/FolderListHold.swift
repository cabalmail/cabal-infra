import Foundation
import CabalmailKit

/// One main window's hold on its folder list, above the layout switch: the
/// selection a layout swap hands to the list the new layout builds, and
/// where the window's list is scrolled (`place`), which the folder's next
/// list reopens at.
///
/// A list records the place, and takes an anchor parked for it, only under
/// the claim it took when it mounted (`ListPlaceTracker`). A newer list's
/// claim, a change of layout, a hand-off, a folder change and a back-out
/// each void the claims before them, so a list from a tree a swap is tearing
/// down can neither record nor take the anchor parked for its successor.
///
/// `SceneNavigator` owns one. Not `@Observable`: no view body reads it, as
/// none read the selection when it lived on the navigator.
@MainActor
final class FolderListHold {
    /// A mounted list's right to record the place and take its anchor.
    struct Claim: Equatable, Sendable {
        let folderPath: String
        fileprivate let generation: Int
    }

    /// The window's list place: the top row of its folder list as the list
    /// last recorded it. Nil at the top of the folder.
    private(set) var place: ListAnchor?

    /// The selection of the window's folder list, and that list's folder
    /// (`mailSelection(for:)`).
    private var listSelection: (folderPath: String, model: SelectionModel<MessageRef>)?

    /// Whether a layout swap is handing `listSelection` to the next folder
    /// list.
    private var handsOffSelection = false

    /// Counts the claims taken and voided; the newest claim is the one held.
    private var generation = 0

    /// The layout the newest claim's list is in.
    private var claimIsWide = false

    // MARK: Selection

    /// The selection for a folder list mounting in this window: a new one,
    /// as every list had when the selection lived on its view model, unless
    /// a layout swap is handing over the one the window's list held for the
    /// same folder. Then that one, so a multi-selection survives the swap. A
    /// hand-off goes to one list; a list mounting after it, in the same tree
    /// or once the folder changes, starts afresh as it always did.
    func mailSelection(for folderPath: String) -> SelectionModel<MessageRef> {
        defer { handsOffSelection = false }
        if handsOffSelection, let held = listSelection, held.folderPath == folderPath {
            return held.model
        }
        let fresh = SelectionModel<MessageRef>()
        listSelection = (folderPath, fresh)
        return fresh
    }

    // MARK: Swaps, folder changes and back-outs

    /// The window's layout changed, away from the wide one or to it: a
    /// folder list in the layout it left goes with its tree, so its claim is
    /// void now. The new layout may build no mail tree for a while (a fold
    /// with Settings open lands on the Settings tab), and until one hands
    /// off, the old list's last reports, its scroll view collapsing to the
    /// top among them, would otherwise move the place. The place itself
    /// stays for the hand-off to park. A claim taken in the layout arrived
    /// at is the new list's, whichever of the two the window heard of first,
    /// and stays.
    func leaveLayout(wide: Bool) {
        if claimIsWide == wide { generation += 1 }
    }

    /// A tree built by a layout swap is taking the window over: the window's
    /// selection goes to the tree's list if it survives the swap
    /// (`SelectionModel.handOff(toWide:)`), the list's place is parked for
    /// that list when it is `folderPath`'s, and the old list's claim is void.
    /// The place stays, so a second swap before the new list lands parks it
    /// again.
    func handOff(isWide: Bool, folderPath: String?, parkingIn restores: WindowRestores) {
        handsOffSelection = listSelection?.model.handOff(toWide: isWide) ?? false
        if let place, place.folderPath == folderPath { restores.parkListAnchor(place) }
        generation += 1
    }

    /// The window moved to another folder (`folderPath`, nil for none): the
    /// old list's selection went with it, as it did when the selection lived
    /// on the list's view model, and so do its place and an anchor parked
    /// for it. An anchor already parked for the folder being landed on
    /// stays for that folder's list.
    func drop(from restores: WindowRestores, landingOn folderPath: String?) {
        listSelection = nil
        restores.dropListAnchor(keeping: folderPath)
        if place?.folderPath != folderPath { place = nil }
        generation += 1
    }

    /// The compact layout backed out to the folder list: the message list
    /// is gone, with its selection and any anchor parked for it. The place
    /// stays, for the same folder picked again.
    func backOut(from restores: WindowRestores) {
        listSelection = nil
        restores.dropListAnchor(keeping: nil)
        generation += 1
    }

    // MARK: The place

    /// Taken by a folder list as it mounts, in the layout the window is in
    /// (`isWide`). The newest claim is the only one held.
    func claim(_ folderPath: String, isWide: Bool) -> Claim {
        generation += 1
        claimIsWide = isWide
        return Claim(folderPath: folderPath, generation: generation)
    }

    func holds(_ claim: Claim) -> Bool {
        claim.generation == generation
    }

    /// Records where the claiming list is scrolled; nil at the top. Refused
    /// under a void claim, or for another folder's anchor. Returns whether
    /// the place changed.
    @discardableResult
    func record(_ anchor: ListAnchor?, under claim: Claim) -> Bool {
        guard holds(claim), anchor.map({ $0.folderPath == claim.folderPath }) ?? true, anchor != place
        else { return false }
        place = anchor
        return true
    }

    /// The anchor a list landing under `claim` scrolls to: one parked for
    /// its folder (taken once), else the window's place when it is that
    /// folder's, as for the same folder's list mounting again after a
    /// search.
    func takeAnchor(under claim: Claim, from restores: WindowRestores) -> ListAnchor? {
        guard holds(claim) else { return nil }
        if let parked = restores.consumeListAnchor(for: claim.folderPath) { return parked }
        return place?.folderPath == claim.folderPath ? place : nil
    }
}
