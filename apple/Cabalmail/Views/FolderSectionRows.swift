import Foundation
import CabalmailKit

/// One drawable row of a sidebar folder section: the folder plus the two
/// things that depend on which section is drawing it.
struct FolderSectionRow: Identifiable, Equatable {
    let folder: Folder
    /// Indentation steps — one per ancestor this section shows.
    let depth: Int
    /// Whether this section has rows the folder's chevron can hide.
    let hasChildren: Bool

    var id: String { folder.path }
}

/// Turns a section's folder list into its rows. Pure, so the sidebar's
/// tree rules are testable without standing up a `List`.
///
/// The sidebar draws the same folders through two sections over two
/// different lists — Subscribed is a subset of All folders, and the
/// filter field narrows both — so depth, the chevron, and the
/// collapse all have to be computed against the section's own list.
/// Reading any of them off the full folder set is what let Subscribed
/// draw a nested folder flat and hand it a chevron whose collapse only
/// took effect in the section below it.
enum FolderSectionRows {
    static func rows(
        for folders: [Folder],
        collapsed: Set<String>,
        activeSelection: String?
    ) -> [FolderSectionRow] {
        let (visible, _) = FolderTree.visibleFolders(
            from: folders,
            collapsed: collapsed,
            activeSelection: activeSelection
        )
        return visible.map { folder in
            FolderSectionRow(
                folder: folder,
                depth: FolderTree.depth(for: folder, in: folders),
                hasChildren: FolderTree.hasChildren(folder, in: folders)
            )
        }
    }
}
