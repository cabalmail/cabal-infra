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
    /// In-message scroll anchor to reapply once the body finishes loading (a
    /// child-index path + delta produced by a prior `onScrollCaptured`, resumed
    /// from the nav cursor). Nil for a normal open. See `NavStateCoordinator`.
    var restoreAnchor: String?
    /// Reports the current scroll anchor while the message is on screen (polled
    /// off the SwiftUI render loop). The reader relays it to the nav cursor so
    /// the position survives across launches and devices.
    var onScrollCaptured: ((String) -> Void)?

    /// Link the user primary-activated, driving the action popover; its
    /// anchor rect is copied to `menuAnchor` first because
    /// `popover(item:attachmentAnchor:)` takes the anchor as a modifier
    /// argument, not per-item.
    @State private var linkMenu: LinkMenuTarget?
    @State private var menuAnchor: CGRect = .zero
    /// Href under the pointer (trackpad / mouse), shown in the status pill.
    @State private var hoveredHref: String?
    @Environment(\.openURL) private var openURL

    init(
        html: String,
        inlineImages: [String: URL],
        allowRemote: Bool,
        readerMode: Bool,
        printRequestTick: Int = 0,
        restoreAnchor: String? = nil,
        onScrollCaptured: ((String) -> Void)? = nil
    ) {
        self.html = html
        self.inlineImages = inlineImages
        self.allowRemote = allowRemote
        self.readerMode = readerMode
        self.printRequestTick = printRequestTick
        self.restoreAnchor = restoreAnchor
        self.onScrollCaptured = onScrollCaptured
    }

    var body: some View {
        platformView
            .overlay(alignment: .bottomLeading) { hoverStatusPill }
            .popover(
                item: $linkMenu,
                attachmentAnchor: .rect(.rect(menuAnchor))
            ) { target in
                LinkActionMenuView(target: target) { action in
                    handleLinkMenuAction(action, for: target)
                }
                .presentationCompactAdaptation(.popover)
            }
            .animation(.easeInOut(duration: 0.15), value: hoveredHref)
    }

    @ViewBuilder
    private var platformView: some View {
        #if os(macOS)
        MacHTMLView(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            printRequestTick: printRequestTick,
            restoreAnchor: restoreAnchor,
            onScrollCaptured: onScrollCaptured,
            onLinkTap: presentLinkMenu,
            onLinkHover: { hoveredHref = $0 }
        )
        #else
        MobileHTMLView(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            printRequestTick: printRequestTick,
            restoreAnchor: restoreAnchor,
            onScrollCaptured: onScrollCaptured,
            onLinkTap: presentLinkMenu,
            onLinkHover: { hoveredHref = $0 }
        )
        #endif
    }

    /// Safari-style status pill: shows the hovered link's destination at
    /// the bottom-leading edge. Hit-testing is off so it never steals
    /// clicks from content beneath it.
    @ViewBuilder
    private var hoverStatusPill: some View {
        if let hoveredHref {
            Text(hoveredHref)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func presentLinkMenu(for target: LinkMenuTarget) {
        hoveredHref = nil
        menuAnchor = target.rect
        linkMenu = target
    }

    private func handleLinkMenuAction(
        _ action: LinkActionMenuView.Action,
        for target: LinkMenuTarget
    ) {
        switch action {
        case .copyText:
            copyToPasteboard(target.text)
        case .copyAddress:
            copyToPasteboard(target.url.absoluteString)
        case .open:
            openURL(target.url)
        }
        linkMenu = nil
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
    let restoreAnchor: String?
    let onScrollCaptured: ((String) -> Void)?
    let onLinkTap: (LinkMenuTarget) -> Void
    let onLinkHover: (String?) -> Void

    func makeCoordinator() -> HTMLBodyCoordinator {
        HTMLBodyCoordinator(allowRemote: allowRemote)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        context.coordinator.installLinkBridge(on: configuration.userContentController)
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
        context.coordinator.onScrollCaptured = onScrollCaptured
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.onLinkHover = onLinkHover
        context.coordinator.render(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            on: uiView
        )
        context.coordinator.handlePrintTick(printRequestTick, for: uiView)
        context.coordinator.updateRestoreAnchor(restoreAnchor, on: uiView)
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
    let restoreAnchor: String?
    let onScrollCaptured: ((String) -> Void)?
    let onLinkTap: (LinkMenuTarget) -> Void
    let onLinkHover: (String?) -> Void

    func makeCoordinator() -> HTMLBodyCoordinator {
        HTMLBodyCoordinator(allowRemote: allowRemote)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        context.coordinator.installLinkBridge(on: configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // See the iOS equivalent for why original mode pins .aqua: author
        // CSS assumes a white page. Reader mode owns the palette via its
        // `prefers-color-scheme` stylesheet, so it tracks the system.
        nsView.appearance = readerMode ? nil : NSAppearance(named: .aqua)
        context.coordinator.onScrollCaptured = onScrollCaptured
        context.coordinator.onLinkTap = onLinkTap
        context.coordinator.onLinkHover = onLinkHover
        context.coordinator.render(
            html: html,
            inlineImages: inlineImages,
            allowRemote: allowRemote,
            readerMode: readerMode,
            on: nsView
        )
        context.coordinator.handlePrintTick(printRequestTick, for: nsView)
        context.coordinator.updateRestoreAnchor(restoreAnchor, on: nsView)
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
    /// Reports the current in-message scroll anchor to the reader. Set from
    /// `update*View`; invoked by the capture poll.
    var onScrollCaptured: ((String) -> Void)?
    /// Presents the link action menu for a primary-activated link. Set
    /// from `update*View`; invoked by the link bridge (see
    /// `HTMLBodyView+LinkBridge`).
    var onLinkTap: ((LinkMenuTarget) -> Void)?
    /// Reports the href under the pointer (nil when it leaves a link) so
    /// the host view can show / hide the status pill.
    var onLinkHover: ((String?) -> Void)?
    /// Scroll anchor to reapply once the page has loaded, or nil for a normal
    /// open. Applied exactly once (`didApplyRestore`).
    private var restoreAnchor: String?
    private var didApplyRestore = false
    private var didFinishLoad = false
    /// Polls the page for its scroll anchor while it's on screen. Scoped to the
    /// web view's lifetime (cancelled on deinit) so it never touches the
    /// SwiftUI render loop. Started after the first load so it can't capture the
    /// pre-restore top-of-page position.
    private var pollTask: Task<Void, Never>?

    init(allowRemote: Bool) {
        self.allowRemote = allowRemote
    }

    deinit {
        pollTask?.cancel()
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
        // Link activations never navigate the reader in place: primary
        // clicks are intercepted by the link bridge (which shows the
        // action menu), so anything arriving here came from a path the
        // bridge can't anchor a menu to — e.g. "Open Link" in the
        // system context menu. Route web links to the default browser
        // instead of replacing the message body.
        if navigationAction.navigationType == .linkActivated {
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                Self.openExternally(url)
            }
            return .cancel
        }
        return allowRemote ? .allow : .cancel
    }

    /// Environment-free external open for delegate callbacks (the SwiftUI
    /// `openURL` action lives on the view, not the coordinator).
    private static func openExternally(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - In-message scroll capture / restore

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoad = true
        applyRestoreIfNeeded(on: webView)
        startPollingIfNeeded(on: webView)
    }

    /// Records the target anchor and, if the page has already finished loading
    /// (the anchor can arrive after `didFinish` when the reader consumes it just
    /// after the body appears), applies it immediately. A no-op once applied.
    func updateRestoreAnchor(_ anchor: String?, on webView: WKWebView) {
        restoreAnchor = anchor
        if didFinishLoad {
            applyRestoreIfNeeded(on: webView)
        }
    }

    /// Runs our restore script once: it walks the child-index path to the
    /// anchored element and `scrollIntoView`s it, then nudges by the saved
    /// delta. Re-run once after a short delay because inline images decoding
    /// after `didFinish` can still shift layout. `nil`/empty anchors no-op.
    private func applyRestoreIfNeeded(on webView: WKWebView) {
        guard !didApplyRestore, let anchor = restoreAnchor, !anchor.isEmpty else { return }
        didApplyRestore = true
        let script = Self.restoreScript(anchor: anchor)
        webView.evaluateJavaScript(script, completionHandler: nil)
        Task { [weak webView] in
            try? await Task.sleep(for: .milliseconds(400))
            // Deliberately NOT the async evaluateJavaScript variant: the
            // restore script's IIFE returns undefined and the async
            // refinement traps on nil results. The sync closure keeps the
            // nil-safe completion-handler API out of the async context.
            await MainActor.run { webView?.evaluateJavaScript(script, completionHandler: nil) }
        }
    }

    private func startPollingIfNeeded(on webView: WKWebView) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, weak webView] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, let webView else { return }
                await self.captureAndReport(from: webView)
            }
        }
    }

    private func captureAndReport(from webView: WKWebView) async {
        let result = try? await webView.evaluateJavaScript(Self.captureScript)
        guard let anchor = result as? String, !anchor.isEmpty else { return }
        onScrollCaptured?(anchor)
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

// MARK: - Printing

extension HTMLBodyCoordinator {
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
}

// MARK: - Scroll scripts

extension HTMLBodyCoordinator {
    /// Reads the top-most visible element and returns a compact anchor:
    /// `"i<child.index.path>|<delta>"`, or a `"f<fraction>"` fallback when the
    /// top of the viewport isn't over a concrete element. App-initiated (runs
    /// even though page-content JS is disabled); reads geometry only.
    static let captureScript = """
    (function(){
      var se=document.scrollingElement||document.documentElement;
      if(!se){return "";}
      var el=document.elementFromPoint(4,4);
      if(!el||el===document.documentElement||el===document.body){
        var h=se.scrollHeight-se.clientHeight;
        return "f"+(h>0?(se.scrollTop/h).toFixed(4):"0");
      }
      var top=Math.round(el.getBoundingClientRect().top);
      var path=[];
      var n=el;
      while(n&&n.parentElement&&n!==document.body){
        var p=n.parentElement;
        path.unshift(Array.prototype.indexOf.call(p.children,n));
        n=p;
      }
      return "i"+path.join(".")+"|"+top;
    })();
    """

    /// Escapes an arbitrary string into a safe JS double-quoted string literal.
    /// The anchor normally comes from our own `captureScript`, but a cursor row
    /// written by another client is only length/control-char validated
    /// server-side, so escape defensively rather than interpolate raw.
    private static func jsStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Restore counterpart to `captureScript`. The anchor is passed as an
    /// escaped string literal (never interpolated into code), and the index
    /// path is walked as numbers, so no untrusted content ever enters the
    /// evaluated program.
    static func restoreScript(anchor: String) -> String {
        let literal = jsStringLiteral(anchor)
        return """
        (function(a){
          var se=document.scrollingElement||document.documentElement;
          if(!a||!se){return;}
          if(a.charAt(0)==="f"){
            var frac=parseFloat(a.slice(1))||0;
            var h=se.scrollHeight-se.clientHeight;
            window.scrollTo(0,frac*(h>0?h:0));
            return;
          }
          if(a.charAt(0)!=="i"){return;}
          var rest=a.slice(1);
          var bar=rest.indexOf("|");
          var idxPart=bar>=0?rest.slice(0,bar):rest;
          var delta=bar>=0?(parseInt(rest.slice(bar+1),10)||0):0;
          var idxs=idxPart.length?idxPart.split(".").map(Number):[];
          var node=document.body;
          for(var k=0;k<idxs.length;k++){
            if(!node||!node.children||idxs[k]>=node.children.length){node=null;break;}
            node=node.children[idxs[k]];
          }
          if(!node){return;}
          node.scrollIntoView(true);
          window.scrollBy(0,-delta);
        })(\(literal));
        """
    }
}
