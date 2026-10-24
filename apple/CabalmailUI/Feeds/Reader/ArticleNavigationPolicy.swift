import WebKit

/// The article view's navigation decisions, apart from the coordinator so
/// they can be tested without a web view (#1911).
enum ArticleNavigationPolicy {
    /// Page JavaScript is off for the reader document's own load and on for
    /// everything else: the live page needs its scripts, and so does the page
    /// a link in the reader leads to, or the live page the toggle goes back
    /// to. Back, forward and reload leave it on, so a reader document that
    /// comes back from history is held by the policy it carries
    /// (`ArticleReaderDocument.contentPolicy`).
    static func allowsJavaScript(type: WKNavigationType, inMainFrame: Bool, loadingReader: Bool) -> Bool {
        !(loadingReader && inMainFrame && type == .other)
    }

    /// Whether a finished page is rendered in the reader. The toolbar can
    /// still be asking for the reader after a link out of it: that page is
    /// the one the user followed a link to, and it stays as the publisher
    /// served it until the reader is asked for again (#2060). The feed's
    /// saved styling is untouched either way, so the next item still opens
    /// in the reader.
    static func showsReader(wantsReader: Bool, leftThroughLink: Bool) -> Bool {
        wantsReader && !leftThroughLink
    }

    /// Whether a navigation is a link tapped in the reader rendering that
    /// opens a web page in this view. A link that opens a new window has no
    /// main frame here, so it does not count.
    static func leavesReader(type: WKNavigationType, url: URL?, inMainFrame: Bool, showingReader: Bool) -> Bool {
        guard showingReader, inMainFrame, type == .linkActivated,
              let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
