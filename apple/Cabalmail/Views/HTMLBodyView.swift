import SwiftUI
@preconcurrency import WebKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
/// - `cid:` inline image URLs are rewritten to `data:` URIs from
///   `inlineImages` before the HTML is handed to the web view. (A temp
///   `file://` URL can't be used: the document's opaque origin — a side
///   effect of `loadHTMLString(_:baseURL: nil)` — forbids `file://`
///   subresource loads.)
struct HTMLBodyView: View {
    let html: String
    let inlineImages: [String: URL]
    let allowRemote: Bool
    /// When true, a reader-view stylesheet is injected ahead of the author's
    /// HTML to normalize typography, cap line length, and respect the system
    /// light/dark appearance. When false, the author's CSS renders as-is
    /// against a pinned-light WebKit page.
    let readerMode: Bool
    /// Monotonic tick the parent bumps via `MessageDetailViewModel.requestPrint()`
    /// to invoke the system print stack on the embedded `WKWebView`. The
    /// Coordinator tracks the last seen value and only fires when it
    /// advances, so a SwiftUI re-layout (which re-runs `update*View` with
    /// the same tick) doesn't re-trigger printing.
    var printRequestTick: Int = 0

    var body: some View {
        #if os(macOS)
        MacHTMLView(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            printRequestTick: printRequestTick
        )
        #else
        MobileHTMLView(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            printRequestTick: printRequestTick
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
    let printRequestTick: Int

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
        // In reader mode the injected stylesheet owns the palette and is
        // written against `prefers-color-scheme`, so let the system
        // appearance through. In original mode we still have to pin light —
        // author CSS assumes a white page and renders unreadably against a
        // dark inherited palette.
        uiView.overrideUserInterfaceStyle = readerMode ? .unspecified : .light
        uiView.backgroundColor = readerMode ? nil : .white
        context.coordinator.render(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            on: uiView
        )
        context.coordinator.handlePrintTick(printRequestTick, for: uiView)
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
    let printRequestTick: Int

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
        // See the iOS equivalent for why original mode pins .aqua: author
        // CSS assumes a white page. Reader mode owns the palette via its
        // `prefers-color-scheme` stylesheet, so it tracks the system.
        nsView.appearance = readerMode ? nil : NSAppearance(named: .aqua)
        context.coordinator.render(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            on: nsView
        )
        context.coordinator.handlePrintTick(printRequestTick, for: nsView)
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
    /// Hash of the inputs behind the currently-loaded page (HTML, inline
    /// images, remote policy, reader mode). `render` reloads only when this
    /// changes — see its doc comment for why reloading on every `update*View`
    /// breaks remote-image loading.
    private var renderedSignature: Int?
    /// Last `printRequestTick` we acted on. `update*View` runs on every
    /// SwiftUI re-layout; comparing against this value ensures the system
    /// print sheet only opens when the parent's counter actually advances.
    private var lastPrintTick: Int = 0

    init(allowRemote: Bool) {
        self.allowRemote = allowRemote
    }

    /// Called from `update*View` with the current tick. Triggers the
    /// platform print stack against `webView` when the tick has advanced
    /// since our last invocation; no-op otherwise. The initial value (0
    /// matching the view-model default) deliberately doesn't fire so the
    /// first `update*View` after view creation isn't treated as a print
    /// request.
    func handlePrintTick(_ tick: Int, for webView: WKWebView) {
        guard tick > lastPrintTick else {
            // First time we see the view (lastPrintTick still 0) and the
            // tick is also 0: nothing to do but record the baseline.
            lastPrintTick = max(lastPrintTick, tick)
            return
        }
        lastPrintTick = tick
        triggerPrint(on: webView)
    }

    private func triggerPrint(on webView: WKWebView) {
        #if canImport(UIKit)
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true, completionHandler: nil)
        #elseif canImport(AppKit)
        let info = NSPrintInfo.shared
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.run()
        #endif
    }

    // Async variant of the protocol requirement. The completion-handler
    // form ("nearly matches optional requirement") collides with strict
    // concurrency: the iOS 18 SDK marks `decisionHandler` with isolation
    // attributes that our @MainActor class can't restate in a way the
    // compiler considers an exact match. Returning the policy directly
    // sidesteps the closure entirely.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }
        // Always allow the very first `about:blank` that `loadHTMLString`
        // uses as its base, plus any local file URL we injected.
        let allowedSchemes: Set<String> = ["about", "file", "data"]
        if allowedSchemes.contains(url.scheme?.lowercased() ?? "") {
            return .allow
        }
        return allowRemote ? .allow : .cancel
    }

    /// Renders `html` into `webView`, putting the remote-content blocker into
    /// the correct state *before* issuing the load, and skipping the reload
    /// entirely when nothing affecting the output changed.
    ///
    /// The skip is load-bearing. `MessageDetailViewModel` is `@Observable`, so
    /// any observed-property change it reads (flag toggles, attachment loads,
    /// folder-status polling) re-renders `MessageDetailView` and re-runs
    /// `update*View`. The previous code called `loadHTMLString` on every such
    /// call, restarting the page and cancelling every in-flight subresource
    /// request. Fast images (a small logo) finished and survived; slow remote
    /// images (e.g. USPS Informed Delivery mailpiece scans) never finished
    /// before the next reload cancelled them, so they stayed stuck on alt text
    /// no matter how often the user tapped "Show remote content".
    @MainActor
    func render(
        html: String,
        inlineImages: [String: URL],
        allowRemote: Bool,
        readerMode: Bool,
        on webView: WKWebView
    ) {
        self.allowRemote = allowRemote
        let signature = Self.signature(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode
        )
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        let rewritten = rewrite(
            html: html,
            inlineImages: inlineImages,
            readerMode: readerMode
        )
        let controller = webView.configuration.userContentController

        if allowRemote {
            // Remove the blocker synchronously, then load — no async window.
            if let installed = installedBlocker {
                controller.remove(installed)
                installedBlocker = nil
            }
            webView.loadHTMLString(rewritten, baseURL: nil)
            return
        }

        // Remote blocked: the blocker must be installed before the first paint
        // or tracker pixels leak. Install synchronously when the compiled list
        // is already cached; otherwise compile first and only then load, so we
        // never issue a load while the page is unguarded.
        if installedBlocker == nil, let cached = Self.cachedBlocker {
            controller.add(cached)
            installedBlocker = cached
        }
        if installedBlocker != nil {
            webView.loadHTMLString(rewritten, baseURL: nil)
            return
        }
        Task { [weak self, weak webView] in
            let list = await HTMLBodyCoordinator.sharedBlocker()
            guard let self, let webView else { return }
            // Bail if a newer render superseded this one (e.g. the user tapped
            // "Show remote content" while we compiled) — that render already
            // issued its own load with the correct blocker state.
            guard self.renderedSignature == signature else { return }
            if let list, self.installedBlocker == nil {
                webView.configuration.userContentController.add(list)
                self.installedBlocker = list
            }
            webView.loadHTMLString(rewritten, baseURL: nil)
        }
    }

    /// Order-independent hash of everything that affects the rendered page.
    /// Seeded per-process (so values aren't stable across launches), which is
    /// fine: `render` only ever compares it against a value from the same
    /// process lifetime.
    private static func signature(
        html: String,
        inlineImages: [String: URL],
        allowRemote: Bool,
        readerMode: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(allowRemote)
        hasher.combine(readerMode)
        for (cid, url) in inlineImages.sorted(by: { $0.key < $1.key }) {
            hasher.combine(cid)
            hasher.combine(url)
        }
        return hasher.finalize()
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

/// Walks the HTML and rewrites `cid:` URLs (case-insensitive) to the
/// `data:` URIs pulled from the inline-image map. Purely string-level so
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
    *, *::before, *::after {
      background-color: #1c1c1e !important;
      background-image: none !important;
      color: #f2f2f7 !important;
    }
    a { color: #0a84ff !important; }
  }
</style>
"""
