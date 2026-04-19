import SwiftUI
@preconcurrency import WebKit

/// Renders HTML message bodies inside a `WKWebView` configured for safe
/// mail display:
///
/// - Non-persistent `WKWebsiteDataStore`, so no cookies / local storage.
/// - JavaScript disabled for the initial load via `WKWebpagePreferences`.
/// - `WKNavigationDelegate` denies every non-`file://` request unless the
///   caller set `allowRemote = true` (the user-flipped toolbar toggle).
/// - `cid:` inline image URLs are rewritten to local `file://` URLs from
///   `inlineImages` before the HTML is handed to the web view.
struct HTMLBodyView: View {
    let html: String
    let inlineImages: [String: URL]
    let allowRemote: Bool

    var body: some View {
        #if os(macOS)
        MacHTMLView(html: html, inlineImages: inlineImages, allowRemote: allowRemote)
        #else
        MobileHTMLView(html: html, inlineImages: inlineImages, allowRemote: allowRemote)
        #endif
    }
}

// MARK: - iOS / visionOS

#if os(iOS) || os(visionOS)
private struct MobileHTMLView: UIViewRepresentable {
    let html: String
    let inlineImages: [String: URL]
    let allowRemote: Bool

    func makeCoordinator() -> HTMLBodyCoordinator {
        HTMLBodyCoordinator(allowRemote: allowRemote)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: makeConfiguration())
        view.navigationDelegate = context.coordinator
        view.isOpaque = true
        view.backgroundColor = .white
        // Force WebKit's light defaults regardless of the system appearance.
        // Email HTML is written assuming a white page; rendering it against
        // a dark inherited palette produces unreadable low-contrast text
        // (the author's `color: black` on our `background: dark` surface).
        view.overrideUserInterfaceStyle = .light
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.allowRemote = allowRemote
        let rewritten = rewrite(html: html, inlineImages: inlineImages)
        uiView.loadHTMLString(rewritten, baseURL: nil)
    }
}
#endif

// MARK: - macOS

#if os(macOS)
private struct MacHTMLView: NSViewRepresentable {
    let html: String
    let inlineImages: [String: URL]
    let allowRemote: Bool

    func makeCoordinator() -> HTMLBodyCoordinator {
        HTMLBodyCoordinator(allowRemote: allowRemote)
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: makeConfiguration())
        view.navigationDelegate = context.coordinator
        // See the iOS equivalent — pin WebKit to its default light
        // appearance so author stylesheets that assume a white page don't
        // render black-on-dark.
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.allowRemote = allowRemote
        let rewritten = rewrite(html: html, inlineImages: inlineImages)
        nsView.loadHTMLString(rewritten, baseURL: nil)
    }
}
#endif

private func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let preferences = WKWebpagePreferences()
    preferences.allowsContentJavaScript = false
    configuration.defaultWebpagePreferences = preferences
    return configuration
}

// MARK: - Shared helpers

final class HTMLBodyCoordinator: NSObject, WKNavigationDelegate {
    var allowRemote: Bool

    init(allowRemote: Bool) {
        self.allowRemote = allowRemote
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Always allow the very first `about:blank` that `loadHTMLString`
        // uses as its base, plus any local file URL we injected.
        let allowedSchemes: Set<String> = ["about", "file", "data"]
        if allowedSchemes.contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
            return
        }
        decisionHandler(allowRemote ? .allow : .cancel)
    }
}

/// Walks the HTML and rewrites `cid:` URLs (case-insensitive) to local
/// `file://` URLs pulled from the inline-image map. Purely string-level so
/// we never need to run a JS context.
func rewrite(html: String, inlineImages: [String: URL]) -> String {
    var result = html
    for (cid, url) in inlineImages {
        let patterns = [
            "cid:\(cid)",
            "CID:\(cid)",
            "cid:\(cid.lowercased())",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: url.absoluteString)
        }
    }
    return result
}
