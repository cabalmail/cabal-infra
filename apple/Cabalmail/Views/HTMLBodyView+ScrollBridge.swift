import Foundation
@preconcurrency import WebKit

/// One report of where the reader is in an HTML body: the DOM anchor
/// (`i<path>|<delta>` / `f<fraction>`, see `HTMLBodyCoordinator.
/// anchorFunctionSource`) plus whether the page is at the top, so the
/// receiver can clear a saved position instead of storing a trivial one.
struct ScrollCapture: Equatable, Sendable {
    /// Below this many CSS pixels of scroll the page counts as "at the top" —
    /// the same 8pt the plain-text reader uses for its reporting threshold.
    static let topThreshold = 8

    let anchor: String
    let isAtTop: Bool

    init(anchor: String, isAtTop: Bool) {
        self.anchor = anchor
        self.isAtTop = isAtTop
    }

    /// From the `{anchor, top}` payload both the scroll bridge and the poll
    /// produce. Nil when the anchor is missing or empty (no scrolling
    /// element yet).
    init?(bridgePayload payload: [String: Any]) {
        guard let anchor = payload["anchor"] as? String, !anchor.isEmpty else { return nil }
        let top = (payload["top"] as? NSNumber)?.intValue ?? 0
        self.init(anchor: anchor, isAtTop: top < Self.topThreshold)
    }
}

/// JS→native bridge reporting the reader's scroll position as the user
/// reads, so the last stretch before leaving an item isn't lost to the
/// fallback poll's interval. Same arrangement as the link bridge: an
/// app-injected `WKUserScript` (which runs while page-content JavaScript
/// stays disabled) and a weakly-held relay. The script posts the anchor
/// after each scroll settles — trailing-debounced `scroll` events, or
/// `scrollend` where WebKit fires it.
extension HTMLBodyCoordinator {
    static let scrollBridgeHandlerName = "cabalScroll"

    /// Installs the scroll user script and message relay on `controller`.
    /// Called once per web view at `make*View` time.
    func installScrollBridge(on controller: WKUserContentController) {
        let script = WKUserScript(
            source: Self.scrollBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        controller.add(
            ScrollBridgeRelay(target: self),
            name: Self.scrollBridgeHandlerName
        )
    }

    func handleScrollBridgeMessage(_ payload: [String: Any]) {
        // Nothing before the first load finished: a layout-time scroll event
        // could otherwise report the pre-restore top of page.
        guard didFinishLoad, let capture = ScrollCapture(bridgePayload: payload) else { return }
        onScrollCaptured?(capture)
    }

    /// Settle delay after the last `scroll` event before reporting, in ms.
    /// Short enough that a back-navigation right after a flick still lands
    /// the report; long enough not to post on every frame of a drag.
    static let scrollBridgeSettleMilliseconds = 250

    /// The injected script. Passive listener so it can never delay
    /// scrolling; `scrollend` (where supported) short-circuits the debounce.
    static let scrollBridgeScript = """
    (function () {
      if (window.__cabalScrollBridge) { return; }
      window.__cabalScrollBridge = true;
      var mh = window.webkit && window.webkit.messageHandlers;
      var handler = mh && mh.\(scrollBridgeHandlerName);
      if (!handler) { return; }
      \(anchorFunctionSource)
      var timer = null;
      function report() {
        timer = null;
        var se = document.scrollingElement || document.documentElement;
        handler.postMessage({ kind: "scroll", anchor: __cabalAnchor(), top: se ? Math.round(se.scrollTop) : 0 });
      }
      window.addEventListener("scroll", function () {
        if (timer) { clearTimeout(timer); }
        timer = setTimeout(report, \(scrollBridgeSettleMilliseconds));
      }, { passive: true });
      window.addEventListener("scrollend", function () {
        if (timer) { clearTimeout(timer); }
        report();
      });
    })();
    """
}

/// Mirrors `LinkBridgeRelay`: `WKUserContentController` retains its message
/// handlers strongly, so the relay holds the coordinator weakly to avoid a
/// retain cycle through the web view's configuration.
private final class ScrollBridgeRelay: NSObject, WKScriptMessageHandler {
    private weak var target: HTMLBodyCoordinator?

    init(target: HTMLBodyCoordinator) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any] else { return }
        let target = self.target
        Task { @MainActor in
            target?.handleScrollBridgeMessage(payload)
        }
    }
}
