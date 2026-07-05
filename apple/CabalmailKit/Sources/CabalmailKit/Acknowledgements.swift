import Foundation

/// A third-party open-source component bundled into the Apple clients,
/// paired with the license text that must ship alongside it.
///
/// The Apple app is distributed through the App Store, so the permissive
/// attribution terms of its bundled dependencies genuinely attach — unlike
/// the server-side Docker/Lambda artifacts, which are built and run only on
/// our own infrastructure and convey no copies to third parties.
/// `CabalmailKit` has no third-party Swift dependencies; the only bundled
/// third-party code is the pair of JavaScript libraries vendored into the
/// rich-text composer's `WKWebView` (see `apple/scripts/sync-vendored.sh`).
public struct ThirdPartyComponent: Identifiable, Sendable {
    public var id: String { name }

    /// Human-readable component name, e.g. `"marked"`.
    public let name: String

    /// One-line description of what the component does and why it ships.
    public let summary: String

    /// SPDX license identifier, e.g. `"MIT"`.
    public let license: String

    /// Upstream project home page.
    public let url: String

    /// Full license text exactly as published upstream, loaded from the
    /// bundled `*-LICENSE` resource. Empty only when the vendored resource
    /// is absent — a local build that skipped `sync-vendored.sh`; CI and
    /// release builds always run it.
    public let licenseText: String
}

/// Third-party attribution surfaced in the app's Settings ▸ About ▸
/// Acknowledgements screen. Mirrors the React admin app's "Third-party
/// notices" section, which does the same for the web client's bundle.
public enum Acknowledgements {
    /// The open-source components bundled into the shipped app, each with
    /// its full upstream license text. Order is fixed for stable display.
    public static func bundledComponents() -> [ThirdPartyComponent] {
        [
            ThirdPartyComponent(
                name: "marked",
                summary: "Markdown parser powering the rich-text composer.",
                license: "MIT",
                url: "https://github.com/markedjs/marked",
                licenseText: licenseText(resource: "marked-LICENSE", extension: "md")
            ),
            ThirdPartyComponent(
                name: "turndown",
                summary: "HTML-to-Markdown converter powering the rich-text composer.",
                license: "MIT",
                url: "https://github.com/mixmark-io/turndown",
                licenseText: licenseText(resource: "turndown-LICENSE", extension: nil)
            ),
        ]
    }

    /// Loads a vendored license file from the bundle. The composer resources
    /// land under the `Resources` subdirectory via `.copy("Compose/Resources")`
    /// in `Package.swift` — the same location `RichTextEditorController`
    /// loads `editor.html` from.
    private static func licenseText(resource: String, extension ext: String?) -> String {
        guard
            let url = Bundle.module.url(
                forResource: resource,
                withExtension: ext,
                subdirectory: "Resources"
            ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return text
    }
}
