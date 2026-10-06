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
/// The sidebar draws whatever list the filter pills and the filter field
/// leave in (`FolderListFilter`), so depth, the chevron, and the collapse
/// all have to be computed against that list rather than the full folder
/// set. Reading any of them off the full set is what once let the old
/// Subscribed section draw a nested folder flat and hand it a chevron
/// whose collapse only took effect in another section.
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
