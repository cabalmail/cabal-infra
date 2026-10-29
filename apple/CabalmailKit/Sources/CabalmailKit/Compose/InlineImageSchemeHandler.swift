import Foundation
// Part of the rich-text composer, which watchOS has no WebKit for
// (`RichTextEditorController.swift`).
#if canImport(WebKit)
import WebKit

/// Serves `cid:` images to the composer's editor page from the host, so an
/// image shown inline in the body is `<img src="cid:<id>">` in the editor:
/// the reference the sent message carries, with no rewriting between what
/// the editor holds and what goes on the wire, and one that survives a
/// round trip through Markdown. A `cid:` the host does not know (a quoted
/// message's own inline image) fails to load, as before.
@MainActor
public final class InlineImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cid"

    /// An inline image's bytes and MIME type, by the bare Content-ID its
    /// `cid:` names; nil for one the host doesn't have.
    public var provider: (@MainActor (_ contentID: String) -> (data: Data, mimeType: String)?)?

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let contentID = Self.contentID(of: url),
              let image = provider?(contentID) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: image.mimeType, expectedContentLength: image.data.count, textEncodingName: nil
        ))
        urlSchemeTask.didReceive(image.data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    /// The bare Content-ID a `cid:` URL names (RFC 2392), percent-decoded.
    static func contentID(of url: URL) -> String? {
        let prefix = "\(scheme):"
        let string = url.absoluteString
        guard string.lowercased().hasPrefix(prefix) else { return nil }
        let encoded = String(string.dropFirst(prefix.count))
        guard let decoded = encoded.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }
}
#endif
