import Foundation

/// Walks the HTML and rewrites `cid:` URLs (case-insensitive) to the
/// `data:` URIs pulled from the inline-image map. Purely string-level so
/// we never need to run a JS context. In `readerMode`, prepends a reset +
/// typography stylesheet that overrides author CSS for a Safari Reader-
/// style presentation. Both modes get a default viewport meta and a default
/// (author-overridable) brand link color.
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
    return insertingHeadDefaults(into: result)
}

/// Injected on both render paths. Without it WebKit lays the document out
/// at its 980pt desktop viewport and scales the result down to the pane
/// width — about 40% on a phone — so any message that ships no viewport of
/// its own (including the HTML alternative our own `/send` generates) is
/// unreadable without pinch-zoom. Unlike the reader stylesheet this is
/// presentation-neutral: it sets the layout viewport, it doesn't override
/// author CSS.
private let viewportMeta =
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"

/// Also injected on both paths, and for the same reason: it replaces a
/// WebKit default rather than overriding the author. A message that ships no
/// link CSS of its own would otherwise render the browser's blue, which is
/// the one bit of chrome in an untouched message that reads as "web page"
/// instead of "Cabalmail". The selector is deliberately bare `a` and carries
/// no `!important`, so any author declaration — a later `a { color: ... }`,
/// a higher-specificity selector, or an inline `style=` — still wins, and
/// author fidelity in "Original" mode is preserved. Only the light variant
/// is stated because Original mode pins the web view to a light appearance;
/// in reader mode the reader stylesheet's `!important` rules supersede this
/// in both appearances.
private let defaultLinkStyle =
    "<style>a { color: \(brandLinkColorLight); }</style>"

/// Places the head defaults at the *start* of the document head, so a sender
/// that declares its own viewport still wins (WebKit takes the last
/// declaration in document order). The insertion point matters: prepending
/// ahead of a `<!DOCTYPE>` would push the author's page into quirks mode
/// and change how their CSS renders, which is exactly what "Original" mode
/// must not do.
private func insertingHeadDefaults(into html: String) -> String {
    let headDefaults = viewportMeta + defaultLinkStyle
    // `<head>` first, then `<html>`, then the doctype; a bare fragment has
    // none of them and can simply be prefixed (the parser synthesizes the
    // head around it).
    for tag in ["<head", "<html", "<!doctype"] {
        guard let open = html.range(of: tag, options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex)
        else { continue }
        return html.replacingCharacters(
            in: close,
            with: ">" + headDefaults
        )
    }
    return headDefaults + html
}

/// Link color in reader mode: the brand forest green rather than the
/// platform link blue, so the reader reads as part of the app instead of a
/// generic web view. These are the light and dark components of the
/// `AccentColor` colorset, restated as hex because the stylesheet is CSS —
/// WebKit resolves the light/dark split from `prefers-color-scheme`, not
/// from the asset catalog. Keep them in step with
/// `Assets.xcassets/AccentColor.colorset` in both app targets.
private let brandLinkColorLight = "#2b633a"
private let brandLinkColorDark = "#79c289"

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
  a { color: \(brandLinkColorLight) !important; text-decoration: underline !important; }
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
    a { color: \(brandLinkColorDark) !important; }
  }
</style>
"""
