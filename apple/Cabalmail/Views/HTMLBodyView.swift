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
    /// When true, a reader-view stylesheet is injected ahead of the author's
    /// HTML to normalize typography, cap line length, and respect the system
    /// light/dark appearance. When false, the author's CSS renders as-is
    /// against a pinned-light WebKit page.
    let readerMode: Bool

    var body: some View {
        #if os(macOS)
        MacHTMLView(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode
        )
        #else
        MobileHTMLView(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode
        )
        #endif
    }
}

// MARK: - iOS / visionOS

#if os(iOS) || os(visionOS)
private struct MobileHTMLView: UIViewRepresentable {
    let html: String
    let inlineImages: [String: URL]
    let allowRemote: Bool
    let readerMode: Bool

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
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.allowRemote = allowRemote
        context.coordinator.apply(allowRemote: allowRemote, to: uiView)
        // In reader mode the injected stylesheet owns the palette and is
        // written against `prefers-color-scheme`, so let the system
        // appearance through. In original mode we still have to pin light —
        // author CSS assumes a white page and renders unreadably against a
        // dark inherited palette.
        uiView.overrideUserInterfaceStyle = readerMode ? .unspecified : .light
        uiView.backgroundColor = readerMode ? nil : .white
        let rewritten = rewrite(
            html: html,
            inlineImages: inlineImages,
            readerMode: readerMode
        )
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
    let readerMode: Bool

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
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.allowRemote = allowRemote
        context.coordinator.apply(allowRemote: allowRemote, to: nsView)
        // See the iOS equivalent for why original mode pins .aqua: author
        // CSS assumes a white page. Reader mode owns the palette via its
        // `prefers-color-scheme` stylesheet, so it tracks the system.
        nsView.appearance = readerMode ? nil : NSAppearance(named: .aqua)
        let rewritten = rewrite(
            html: html,
            inlineImages: inlineImages,
            readerMode: readerMode
        )
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
/// we never need to run a JS context. In `readerMode`, prepends a reset +
/// typography stylesheet that overrides author CSS for a Safari Reader-
/// style presentation.
func rewrite(
    html: String,
    inlineImages: [String: URL],
    readerMode: Bool = false
) -> String {
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
    if readerMode {
        result = readerStylesheet + result
    }
    return result
}

/// Prepended in reader mode. Every rule uses `!important` because most
/// author mail CSS ships as inline `style=` attributes, and we need to win
/// the cascade against both inline styles and higher-specificity selectors.
///
/// Design goals: system font, capped reading width, transparent author
/// backgrounds so colored wrappers don't clash with the system surface, and
/// a `prefers-color-scheme: dark` branch so the page follows the user's
/// system appearance (which is why `readerMode` also drops the `.light`
/// WebKit override in the host view).
private let readerStylesheet = """
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html, body {
    margin: 0 !important;
    padding: 0 !important;
    background: #ffffff !important;
    color: #1c1c1e !important;
    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif !important;
    font-size: 17px !important;
    line-height: 1.6 !important;
  }
  body {
    padding: 20px !important;
    max-width: 680px !important;
    margin: 0 auto !important;
  }
  *, *::before, *::after {
    background-color: transparent !important;
    background-image: none !important;
    max-width: 100% !important;
    box-sizing: border-box !important;
  }
  img, video { height: auto !important; }
  a { color: #0a84ff !important; text-decoration: underline !important; }
  blockquote {
    margin: 1em 0 !important;
    padding: 0 1em !important;
    border-left: 3px solid rgba(127,127,127,0.35) !important;
    color: inherit !important;
  }
  table { border-collapse: collapse !important; width: auto !important; }
  td, th { padding: 4px 8px !important; border: none !important; }
  pre, code {
    font-family: ui-monospace, "SF Mono", Menlo, monospace !important;
    font-size: 0.9em !important;
    background: rgba(127,127,127,0.12) !important;
    border-radius: 4px !important;
    padding: 2px 4px !important;
  }
  pre { padding: 12px !important; overflow-x: auto !important; }
  h1, h2, h3, h4, h5, h6 { color: inherit !important; }
  hr { border: none !important; border-top: 1px solid rgba(127,127,127,0.3) !important; }
  @media (prefers-color-scheme: dark) {
    html, body {
      background: #1c1c1e !important;
      color: #f2f2f7 !important;
    }
    a { color: #0a84ff !important; }
  }
</style>
"""
