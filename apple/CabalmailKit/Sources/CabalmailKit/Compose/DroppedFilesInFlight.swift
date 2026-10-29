import Foundation
// Part of the rich-text composer, which watchOS has no WebKit for
// (`RichTextEditorController.swift`).
#if canImport(WebKit)

extension RichTextEditorController {
    /// What the editor page could read of a file dropped onto it.
    public enum DroppedFileContents: Equatable, Sendable {
        case data(Data)
        /// The page could not read it, or its web content process stopped
        /// before it had.
        case unreadable
        /// Larger than the page reads. Its bytes would cross the bridge as
        /// base64, and a very large file could take the page down, and the
        /// draft's rich text with it.
        case tooLarge(limitBytes: Int)
    }
}

/// The files the editor page has said are coming (`dropStarted`) and has not
/// yet delivered (`droppedFile`). Each reaches the host once: a delivery it
/// was not told of, or a second one, is ignored, and the files still due when
/// the page's process stops are handed back to be reported unreadable.
struct DroppedFilesInFlight {
    private var names: [Int: String] = [:]

    /// Records the files a `dropStarted` message names. Returns how many.
    mutating func start(_ payload: [String: Any]) -> Int {
        let files = payload["files"] as? [[String: Any]] ?? []
        var started = 0
        for file in files {
            guard let id = file["id"] as? Int, names[id] == nil else { continue }
            names[id] = file["name"] as? String ?? ""
            started += 1
        }
        return started
    }

    /// The file a `droppedFile` message delivers, under the name it was
    /// announced with, or nil if it was not announced or has already come.
    mutating func arrive(
        _ payload: [String: Any]
    ) -> (name: String, contents: RichTextEditorController.DroppedFileContents)? {
        guard let id = payload["id"] as? Int, let name = names.removeValue(forKey: id) else { return nil }
        if let base64 = payload["base64"] as? String, let data = Data(base64Encoded: base64) {
            return (name, .data(data))
        }
        if payload["tooLarge"] as? Bool == true {
            return (name, .tooLarge(limitBytes: payload["limit"] as? Int ?? 0))
        }
        return (name, .unreadable)
    }

    /// The names of the files still due, in the order they were dropped,
    /// which will now never come. Forgets them.
    mutating func abandon() -> [String] {
        defer { names.removeAll() }
        return names.sorted { $0.key < $1.key }.map(\.value)
    }
}
#endif
