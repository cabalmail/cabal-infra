import Foundation

/// The vendored Readability.js the article view injects for its reader mode
/// (docs/1.x/rss-implementation-plan.md, phase 5). Neither `WKWebView` nor
/// Android's WebView exposes the browser's own reader, so the app extracts
/// the article itself the way Reeder and NetNewsWire do; the operator
/// confirmed this satisfies the "reader view" requirement (2026-09-09).
///
/// Materialized by `apple/scripts/sync-vendored.sh` from
/// `react/admin/node_modules/@mozilla/readability` (the version pin lives in
/// `react/admin/package.json`, where dependabot maintains it) into
/// `RSS/ReaderAssets/`, which is gitignored like the composer's assets.
public enum ReaderAssets {
    /// Readability.js source, or nil when a local build skipped the sync
    /// script (CI and release builds always run it). The article view then
    /// simply offers no reader toggle.
    public static func readabilityScript() -> String? {
        guard let url = Bundle.module.url(
            forResource: "Readability", withExtension: "js", subdirectory: "ReaderAssets"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
