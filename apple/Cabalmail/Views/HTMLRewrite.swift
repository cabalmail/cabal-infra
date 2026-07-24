import Foundation

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
