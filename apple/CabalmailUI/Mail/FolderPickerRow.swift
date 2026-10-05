import SwiftUI
import CabalmailKit

/// One row of a folder picker: a system icon, the folder name, its full path
/// when nested, and an optional trailing accessory.
///
/// `MoveToFolderSheet` and `NotificationFolderPickerView` render the same
/// row — same icons, same 8pt HStack, same depth indent, same tap target —
/// and differ only in what sits after the spacer: the move sheet has
/// nothing there, the notification picker has its selection checkmark.
/// The sidebar's own folder rows are deliberately not on this type; they use
/// a different icon vocabulary (`FolderListView+Helpers.iconName`).
struct FolderPickerRow<Accessory: View>: View {
    let folder: Folder
    let accessory: () -> Accessory

    init(folder: Folder, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.folder = folder
        self.accessory = accessory
    }

    var body: some View {
        let depth = FolderTree.depth(for: folder)
        HStack(spacing: 8) {
            Image(systemName: Self.icon(for: folder))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.body)
                if depth > 0 {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
    }

    static func icon(for folder: Folder) -> String {
        switch folder.path {
        case "INBOX":   return "tray"
        case "Sent":    return "paperplane"
        case "Drafts":  return "pencil.line"
        case "Trash":   return "trash"
        case "Junk":    return "exclamationmark.shield"
        case "Archive": return "archivebox"
        default:        return "folder"
        }
    }
}

extension FolderPickerRow where Accessory == EmptyView {
    init(folder: Folder) {
        self.init(folder: folder) { EmptyView() }
    }
}
