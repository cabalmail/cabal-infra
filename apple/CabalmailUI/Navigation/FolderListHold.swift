import Foundation
import CabalmailKit

/// One main window's hold on its folder list, above the layout switch: the
/// selection a layout swap hands to the list the new layout builds.
///
/// `SceneNavigator` owns one. Not `@Observable`: no view body reads it, as
/// none read the selection when it lived on the navigator.
@MainActor
final class FolderListHold {
    /// The selection of the window's folder list, and that list's folder
    /// (`mailSelection(for:)`).
    private var listSelection: (folderPath: String, model: SelectionModel<MessageRef>)?

    /// Whether a layout swap is handing `listSelection` to the next folder
    /// list.
    private var handsOffSelection = false

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

    /// A tree built by a layout swap is taking the window over: the window's
    /// selection goes to the tree's list if it survives the swap
    /// (`SelectionModel.handOff(toWide:)`).
    func handOff(isWide: Bool) {
        handsOffSelection = listSelection?.model.handOff(toWide: isWide) ?? false
    }

    /// The window's folder list is gone: another folder was picked, or the
    /// compact layout backed out to the folder list. Its selection went with
    /// it, as it did when the selection lived on the list's view model.
    func drop() {
        listSelection = nil
    }
}
