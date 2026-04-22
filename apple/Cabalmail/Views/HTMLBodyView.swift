import SwiftUI
@preconcurrency import WebKit

/// Renders HTML message bodies inside a `WKWebView` configured for safe
/// mail display:
///
/// - Non-persistent `WKWebsiteDataStore`, so no cookies / local storage.
/// - JavaScript disabled for the initial load via `WKWebpagePreferences`.
/// - Remote resource loads (images, CSS, fonts, iframes — the usual tracker-
///   pixel vector) are gated by a `WKContentRuleList` that blocks every
///   `http`/`https` request. The `WKNavigationDelegate` only catches top-
///   level and subframe navigations; subresource loads bypass it entirely,
///   which is why the earlier "deny non-file URLs in `decidePolicyFor`"
///   approach silently loaded tracker pixels despite the preference.
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
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: .zero, configuration: configuration)
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
        context.coordinator.apply(allowRemote: allowRemote, to: uiView)
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
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // See the iOS equivalent — pin WebKit to its default light
        // appearance so author stylesheets that assume a white page don't
        // render black-on-dark.
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.allowRemote = allowRemote
        context.coordinator.apply(allowRemote: allowRemote, to: nsView)
        let rewritten = rewrite(html: html, inlineImages: inlineImages)
        nsView.loadHTMLString(rewritten, baseURL: nil)
    }
}
#endif

// MARK: - Shared helpers

/// Navigation-level + content-blocker coordination for the embedded web
/// view. The content rule list does the heavy lifting against subresources
/// (images, CSS, fonts); the navigation delegate's decision is a secondary
/// guard against top-level navigations the user didn't ask for (e.g. a
/// meta-refresh in the message body).
///
/// `@MainActor` because every entry point (WKNavigationDelegate callbacks,
/// SwiftUI `update*View`, `UIViewRepresentable.Coordinator`) is invoked on
/// the main thread and we touch main-actor UIKit/AppKit state from within.
@MainActor
final class HTMLBodyCoordinator: NSObject, WKNavigationDelegate {
    var allowRemote: Bool
    private var installedBlocker: WKContentRuleList?

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

    /// Installs or removes the remote-blocker content rule list on the web
    /// view's `userContentController`. Idempotent — repeat calls with the
    /// same `allowRemote` value are no-ops, so the SwiftUI `updateUIView`
    /// hot path doesn't churn the controller on every re-layout.
    @MainActor
    func apply(allowRemote: Bool, to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if allowRemote {
            if let installed = installedBlocker {
                controller.remove(installed)
                installedBlocker = nil
            }
            return
        }
        guard installedBlocker == nil else { return }
        Task { [weak self] in
            guard let list = await HTMLBodyCoordinator.sharedBlocker() else { return }
            guard let self else { return }
            // Between scheduling and resumption `allowRemote` may have
            // flipped (the user tapped "Show remote content"); re-check
            // before installing so we don't clobber a now-unblocked view.
            guard !self.allowRemote else { return }
            controller.add(list)
            self.installedBlocker = list
        }
    }

    /// One-time compile of the block-everything-remote rule list. Compilation
    /// is async and slightly expensive; cache the result so every subsequent
    /// message re-uses the same compiled list.
    @MainActor
    private static var cachedBlocker: WKContentRuleList?
    @MainActor
    private static var pendingCompile: Task<WKContentRuleList?, Never>?

    @MainActor
    static func sharedBlocker() async -> WKContentRuleList? {
        if let cached = cachedBlocker { return cached }
        if let pending = pendingCompile { return await pending.value }
        let task = Task<WKContentRuleList?, Never> { @MainActor in
            let json = """
            [
              {
                "trigger": { "url-filter": "^https?://" },
                "action": { "type": "block" }
              }
            ]
            """
            do {
                let list = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "cabalmail-block-remote",
                    encodedContentRuleList: json
                )
                cachedBlocker = list
                return list
            } catch {
                return nil
            }
        }
        pendingCompile = task
        let list = await task.value
        pendingCompile = nil
        return list
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
