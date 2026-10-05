import Foundation

/// The temp folders readers write attachment files to: one per reader, so
/// same-UID messages in two folders can't overwrite each other's files
/// (#1813). They outlive the reader, because Forward reads the files when it
/// runs. Sign-out removes them all, so the next account on the device can't
/// open the last one's attachments.
enum AttachmentFolders {
    static let prefix = "cabalmail-attachments-"

    /// A new reader's folder under `root`, created when its first file is
    /// written.
    static func make(in root: URL = FileManager.default.temporaryDirectory) -> URL {
        root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    }

    /// Removes every reader's folder under `root`.
    static func removeAll(in root: URL = FileManager.default.temporaryDirectory) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? manager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
}
