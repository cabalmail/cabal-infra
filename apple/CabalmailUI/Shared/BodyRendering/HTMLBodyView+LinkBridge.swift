import SwiftUI
@preconcurrency import WebKit

/// JS↔native bridge for link interaction in the reader.
///
/// The reader disables page-content JavaScript
/// (`allowsContentJavaScript = false`), which deliberately does *not*
/// affect app-injected `WKUserScript`s — so this bridge runs while the
/// message's own scripts stay dead. It intercepts primary activation
/// (click / tap) on anchors and reports pointer hover, feeding the link
/// action menu and the Safari-style status pill in `HTMLBodyView`.
/// Secondary interactions (right-click, long-press) are untouched and
/// keep the system-default WebKit menus.
extension HTMLBodyCoordinator {
    static let linkBridgeHandlerName = "cabalLink"

    /// Installs the link user script and message relay on `controller`.
    /// Called once per web view at `make*View` time.
    func installLinkBridge(on controller: WKUserContentController) {
        let script = WKUserScript(
            source: Self.linkBridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        controller.add(
            LinkBridgeRelay(target: self),
            name: Self.linkBridgeHandlerName
        )
    }

    func handleLinkBridgeMessage(_ payload: [String: Any]) {
        switch payload["kind"] as? String {
        case "tap":
            guard let target = LinkMenuTarget(bridgePayload: payload) else { return }
            onLinkTap?(target)
        case "hover":
            // No href = the pointer left the link (hide the pill).
            onLinkHover?(payload["href"] as? String)
        default:
            break
        }
    }

    /// The injected script. Notes on the deliberate carve-outs:
    /// - `#fragment` hrefs keep their default in-page scroll (newsletter
    ///   tables of contents).
    /// - A non-collapsed selection suppresses the menu: the click that
    ///   ends a text-selection drag shouldn't pop UI.
    /// - Coordinates go through `visualViewport` so the popover anchors
    ///   correctly when the page is pinch-zoomed.
    /// - `contextmenu` / long-press never fire `click`, so secondary
    ///   interactions fall through to the system menus untouched.
    private static let linkBridgeScript = """
    (function () {
      if (window.__cabalLinkBridge) { return; }
      window.__cabalLinkBridge = true;
      var mh = window.webkit && window.webkit.messageHandlers;
      var handler = mh && mh.cabalLink;
      if (!handler) { return; }
      function linkFor(node) {
        while (node && node.nodeType === 1) {
          if (node.tagName === "A" && node.getAttribute("href")) { return node; }
          node = node.parentNode;
        }
        return null;
      }
      document.addEventListener("click", function (event) {
        if (event.button !== 0) { return; }
        var link = linkFor(event.target);
        if (!link) { return; }
        if ((link.getAttribute("href") || "").charAt(0) === "#") { return; }
        var selection = window.getSelection();
        if (selection && !selection.isCollapsed) { return; }
        event.preventDefault();
        event.stopPropagation();
        var rect = link.getBoundingClientRect();
        var vv = window.visualViewport;
        var scale = vv ? vv.scale : 1;
        var ox = vv ? vv.offsetLeft : 0;
        var oy = vv ? vv.offsetTop : 0;
        handler.postMessage({
          kind: "tap",
          href: link.href,
          text: (link.textContent || "").slice(0, 2000),
          x: (rect.left - ox) * scale,
          y: (rect.top - oy) * scale,
          w: rect.width * scale,
          h: rect.height * scale
        });
      }, true);
      document.addEventListener("mouseover", function (event) {
        var link = linkFor(event.target);
        if (link) { handler.postMessage({ kind: "hover", href: link.href }); }
      }, true);
      document.addEventListener("mouseout", function (event) {
        if (linkFor(event.target) && !linkFor(event.relatedTarget)) {
          handler.postMessage({ kind: "hover" });
        }
      }, true);
    })();
    """
}

/// Mirrors the compose editor's `BridgeRelay`: `WKUserContentController`
/// retains its message handlers strongly, so the relay holds the
/// coordinator weakly to avoid a retain cycle through the web view's
/// configuration.
private final class LinkBridgeRelay: NSObject, WKScriptMessageHandler {
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
            target?.handleLinkBridgeMessage(payload)
        }
    }
}
