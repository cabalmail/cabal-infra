import Foundation
@preconcurrency import WebKit

/// Dynamic Type for HTML reading content: the mail reader (both stylings)
/// and the feed reader's article rendering. The plain-text body gets it from
/// its `.body` font; an HTML body's sizes are the author's CSS (or, in reader
/// mode, the reader stylesheet's 17px), which the system text size never
/// reaches on its own.
///
/// `rewrite` marks a document with the scale (`DynamicTypeSize.
/// bodyTextScale`) in a meta tag, and a user script installed on the reader's
/// web view multiplies every element's computed font size, and every fixed
/// line height, by it before the page first paints. Like the link and scroll
/// bridges, the script runs in `WKContentWorld.defaultClient`, so it works
/// with page JavaScript off and stays out of the page's reach. At the
/// default size the document carries no meta and the script touches nothing,
/// so "Original" styling is exactly the author's.
///
/// Why not WebKit's own `-webkit-text-size-adjust`: an iPad ignores it in
/// its default (desktop) content mode, and in mobile mode it scales fonts
/// but not fixed `px` line heights, so lines overlap. Scaling both from the
/// computed style behaves the same on every device.
///
/// The scale reaches the page through the document, not the script, because
/// a user script's source is fixed once installed; a new scale renders the
/// document again. A message carrying its own meta of that name gains
/// nothing a sender doesn't already have by setting its own font sizes.
enum ReaderTextScale {
    static let metaName = "cabal-text-scale"

    /// The marker `rewrite` puts in the document head; empty at the default
    /// size, so the script does nothing there.
    static func meta(for scale: Double) -> String {
        guard scale != 1 else { return "" }
        return "<meta name=\"\(metaName)\" content=\"\(scale)\">"
    }

    /// Adds the scaling script to a reader web view's configuration. Called
    /// once per web view, before its first load.
    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
    }

    /// Reads every element's computed size before writing any, so an `em`
    /// child is not scaled twice through its scaled parent, then writes the
    /// scaled sizes as inline `!important` declarations, which outrank the
    /// author's stylesheets and inline styles, `!important` or not. Line
    /// heights that compute to `normal` follow the new font size by
    /// themselves. SVG and MathML are skipped: their text is part of a
    /// drawing. The bounds keep a forged or garbled meta from doing anything
    /// absurd.
    static let script = """
    (function () {
      if (window.__cabalTextScale) { return; }
      window.__cabalTextScale = true;
      var meta = document.querySelector('meta[name="\(metaName)"]');
      var scale = meta ? parseFloat(meta.getAttribute("content")) : NaN;
      if (!(scale >= 0.5 && scale <= 4) || scale === 1) { return; }
      var xhtml = "http://www.w3.org/1999/xhtml";
      var all = document.getElementsByTagName("*");
      var sizes = [];
      for (var i = 0; i < all.length; i++) {
        if (all[i].namespaceURI !== xhtml) { sizes.push(null); continue; }
        var style = getComputedStyle(all[i]);
        var lineHeight = style.lineHeight;
        sizes.push([parseFloat(style.fontSize), /px$/.test(lineHeight) ? parseFloat(lineHeight) : NaN]);
      }
      for (var j = 0; j < sizes.length; j++) {
        var size = sizes[j];
        if (!size) { continue; }
        if (size[0] >= 0) { all[j].style.setProperty("font-size", size[0] * scale + "px", "important"); }
        if (size[1] >= 0) { all[j].style.setProperty("line-height", size[1] * scale + "px", "important"); }
      }
    })();
    """
}
