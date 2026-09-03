// "Open in Private Window" for the reader's link menu (plan Phase 7.3).
//
// No OS API opens a Safari private window, so the mail app hands the link
// to the Cabalmail browser extension instead: it opens the redirector page
// `https://admin.<control-domain>/private-link#<target>` in the default
// browser, and the extension's background intercepts that navigation and
// re-opens the target in a private window. The target rides in the URL
// fragment, which browsers never send to a server, so the admin origin
// never sees or logs it.
//
// Whether the row is offered at all depends on whether anything will catch
// the redirector. When Safari is the default browser, the app can ask —
// the extension is embedded in this very bundle (OQ9), which is the one
// case `SFSafariExtensionManager` can answer for. Any other default
// browser cannot be queried, so the row is offered and the redirector's
// own fallback page explains the setup if nothing intercepts it. Desktop
// only: iOS Safari cannot create private windows through the extension
// API, and iOS keeps the share sheet for private mode.

import Foundation

#if os(macOS)
import AppKit
import SafariServices
#endif

enum PrivateLinkHandoff {
    /// The embedded appex's identifier — `CabalmailMacWebExtension` in
    /// apple/project.yml. `getStateOfSafariExtension` only answers for an
    /// extension contained in the calling app's bundle, which is why this
    /// works now and could not for the standalone host.
    static let safariExtensionID = "com.cabalmail.CabalmailMac.web-extension"

    /// The redirector URL for `target`, or nil when the target is not a web
    /// link (only http/https can be opened in a browser window) or the
    /// control domain is unknown.
    static func redirectorURL(for target: URL, controlDomain: String) -> URL? {
        let domain = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !domain.isEmpty,
            let scheme = target.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let encoded = target.absoluteString.addingPercentEncoding(
                withAllowedCharacters: Self.fragmentUnreserved
            )
        else { return nil }
        return URL(string: "https://admin.\(domain)/private-link#\(encoded)")
    }

    /// `encodeURIComponent`'s unreserved set: the redirector page and the
    /// extension both `decodeURIComponent` the fragment, so the target
    /// survives `?`, `&`, `#` and non-ASCII intact.
    private static let fragmentUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    #if os(macOS)
    /// Whether the row should be offered. Cached after the first answer:
    /// the menu is a popover, and a row that appears a beat after the menu
    /// does would shift every row below it; `prime()` fills the cache at
    /// launch so the first menu of a session is right too.
    @MainActor static private(set) var isAvailable: Bool?

    /// Kick the availability query without waiting on it.
    @MainActor static func prime() {
        guard isAvailable == nil else { return }
        Task { isAvailable = await queryAvailability() }
    }

    /// The default browser is whatever handles an https URL.
    static func defaultBrowserIsSafari() -> Bool {
        guard
            let probe = URL(string: "https://example.com/"),
            let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return false }
        return Bundle(url: appURL)?.bundleIdentifier == "com.apple.Safari"
    }

    /// Safari default: ask whether our extension is enabled. Anything else:
    /// unknowable, so offer the row and let the redirector's fallback page
    /// carry the explanation.
    static func queryAvailability() async -> Bool {
        guard defaultBrowserIsSafari() else { return true }
        return await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(
                withIdentifier: safariExtensionID
            ) { state, _ in
                continuation.resume(returning: state?.isEnabled ?? false)
            }
        }
    }

    /// Hand `target` to the browser via the redirector. Returns false when
    /// there was nothing valid to open.
    @discardableResult
    static func open(_ target: URL, controlDomain: String) -> Bool {
        guard let url = redirectorURL(for: target, controlDomain: controlDomain) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
    #endif
}
