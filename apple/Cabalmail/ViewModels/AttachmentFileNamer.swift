import Foundation

/// Names the files a reader writes a message's attachments to. Each name is
/// made safe for the file system and unique within the message, so two
/// attachments both called `scan.pdf` get two files, `scan.pdf` and
/// `scan 2.pdf`, instead of the second overwriting the first while the
/// attachment strip showed one entry for both (#1813). Uniqueness ignores
/// case, because the default APFS volume does too.
struct AttachmentFileNamer {
    private var used: Set<String> = []

    mutating func name(for filename: String) -> String {
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        let base = safe.isEmpty ? "attachment" : safe
        var candidate = base
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = Self.numbered(base, number)
            number += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// `scan.pdf` becomes `scan 2.pdf`; a name without an extension gets the
    /// number at the end.
    private static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(name) \(number)" : "\(stem) \(number).\(ext)"
    }
}
