import Foundation
// Part of the rich-text composer, which watchOS has no WebKit for
// (`RichTextEditorController.swift`).
#if canImport(WebKit)
import WebKit

/// Files dropped or pasted onto the composer's editor page: a message from a
/// list, an image, any other file. The page inserts none of them itself. It
/// names the files it is about to read (`dropStarted`), then delivers each
/// in a `droppedFile` message, and the host decides: attach the file, or,
/// for an image, show it inline where it was dropped (`placeImage`).
///
/// Each named file reaches the host once: a delivery the page did not name,
/// or a second one, is ignored, and the files still due when the page's
/// process stops are delivered as unreadable, so a host holding Send for
/// them is never left waiting.
@MainActor
public final class EditorFileDrops {
    /// One file the page read, or failed to.
    public struct File: Equatable, Sendable {
        /// The page's id for the file, which `placeImage` and `forget` name.
        public let id: Int
        public let name: String
        public let contents: Contents

        public init(id: Int, name: String, contents: Contents) {
            self.id = id
            self.name = name
            self.contents = contents
        }
    }

    /// What the page could read of a file.
    public enum Contents: Equatable, Sendable {
        case data(Data)
        /// The page could not read it, or its web content process stopped
        /// before it had.
        case unreadable
        /// Larger than the page reads. Its bytes would cross the bridge as
        /// base64, and a very large file could take the page down, and the
        /// draft's rich text with it.
        case tooLarge(limitBytes: Int)
    }

    /// Fires when files are dropped or pasted, with how many `onFile` calls
    /// will follow.
    public var onStarted: (@MainActor (_ count: Int) -> Void)?
    /// Fires once for each file `onStarted` counted.
    public var onFile: (@MainActor (File) -> Void)?

    private var names: [Int: String] = [:]
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// Shows an image file inline in the page, where it was dropped or
    /// pasted and after any image of the same drop already shown, as
    /// `<img src="cid:<contentID>">` (served by `InlineImageSchemeHandler`).
    /// Returns false when the page has no place for it, the file having been
    /// placed or forgotten already, so the host can attach it instead.
    public func placeImage(_ file: File, contentID: String, alt: String) async -> Bool {
        let placed = try? await webView?.callAsyncJavaScript(
            "return window.cabal.placeDroppedImage(id, src, alt);",
            arguments: ["id": file.id, "src": "cid:\(contentID)", "alt": alt],
            contentWorld: .page
        )
        return placed as? Bool == true
    }

    /// Lets the page drop its note of where a file it will not show went.
    public func forget(_ file: File) async {
        _ = try? await webView?.callAsyncJavaScript(
            "window.cabal.forgetDroppedFile(id);",
            arguments: ["id": file.id],
            contentWorld: .page
        )
    }

    /// A `dropStarted` or `droppedFile` message from the page.
    func handle(_ type: String, _ payload: [String: Any]) {
        if type == "dropStarted" {
            let count = start(payload)
            if count > 0 { onStarted?(count) }
        } else if let file = arrive(payload) {
            onFile?(file)
        }
    }

    /// The page's process stopped: the files still due will never come.
    func pageStopped() {
        let due = names.sorted { $0.key < $1.key }
        names.removeAll()
        for (id, name) in due {
            onFile?(File(id: id, name: name, contents: .unreadable))
        }
    }

    private func start(_ payload: [String: Any]) -> Int {
        let files = payload["files"] as? [[String: Any]] ?? []
        var started = 0
        for file in files {
            guard let id = file["id"] as? Int, names[id] == nil else { continue }
            names[id] = file["name"] as? String ?? ""
            started += 1
        }
        return started
    }

    private func arrive(_ payload: [String: Any]) -> File? {
        guard let id = payload["id"] as? Int, let name = names.removeValue(forKey: id) else { return nil }
        if let base64 = payload["base64"] as? String, let data = Data(base64Encoded: base64) {
            return File(id: id, name: name, contents: .data(data))
        }
        if payload["tooLarge"] as? Bool == true {
            return File(id: id, name: name, contents: .tooLarge(limitBytes: payload["limit"] as? Int ?? 0))
        }
        return File(id: id, name: name, contents: .unreadable)
    }
}
#endif
