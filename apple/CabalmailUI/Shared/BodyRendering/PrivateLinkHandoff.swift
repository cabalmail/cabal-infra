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
// On Safari the fragment carries an opaque token instead, resolved by the
// embedded appex out of the App Group (`PrivateLinkTokenStore`, #1765):
// WebKit implements no `history` API, so the extension cannot remove the
// redirector's normal-window history entry there, and an entry carrying
// the target would defeat the point of opening privately. See
// `fragmentForm` for why that form is chosen for Safari only.
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

public enum PrivateLinkHandoff {
    /// The embedded appex's identifier — `CabalmailMacWebExtension` in
    /// apple/project.yml. `getStateOfSafariExtension` only answers for an
    /// extension contained in the calling app's bundle, which is why this
    /// works now and could not for the standalone host.
    static let safariExtensionID = "com.cabalmail.CabalmailMac.web-extension"

    /// The redirector URL for `target`, or nil when the target is not a web
    /// link (only http/https can be opened in a browser window) or the
    /// control domain is unknown.
    static func redirectorURL(for target: URL, controlDomain: String) -> URL? {
        guard
            let domain = normalizedControlDomain(controlDomain),
            let scheme = target.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let encoded = target.absoluteString.addingPercentEncoding(
                withAllowedCharacters: Self.fragmentUnreserved
            )
        else { return nil }
        return URL(string: "https://admin.\(domain)/private-link#\(encoded)")
    }

    /// The redirector URL whose fragment is an opaque token rather than the
    /// target (#1765). The token is minted into the App Group by
    /// `PrivateLinkTokenStore` and resolved by the embedded appex, so the
    /// target never enters a URL -- and so never enters the history entry
    /// Safari has no API to remove.
    static func redirectorURL(forToken token: String, controlDomain: String) -> URL? {
        guard let domain = normalizedControlDomain(controlDomain) else { return nil }
        return URL(string: "https://admin.\(domain)/private-link#\(token)")
    }

    /// Which form the fragment takes.
    enum FragmentForm {
        /// The target itself, percent-encoded. Every browser's extension
        /// can read it, and Chrome deletes the entry afterwards.
        case target
        /// An opaque token, resolved over `sendNativeMessage`.
        case token
    }

    /// The token form is only resolvable where a native host answers
    /// `resolve-private-link`, which is Safari with *our embedded* appex
    /// enabled and nowhere else: Chrome has no registered host, and the
    /// standalone Safari host's handler does not answer that message. A
    /// token the extension cannot resolve would leave the fallback page
    /// with nothing to show at all, so the gate is deliberately narrow.
    ///
    /// `availability` is `isAvailable`'s cache, which is the enablement of
    /// the embedded appex exactly when Safari is the default browser --
    /// `queryAvailability()` returns an optimistic `true` for any other
    /// default precisely because it cannot ask, and that `true` must not
    /// select the token form. An unprimed cache (`nil`) picks the target
    /// form, which works everywhere.
    static func fragmentForm(isSafariDefault: Bool, availability: Bool?) -> FragmentForm {
        isSafariDefault && availability == true ? .token : .target
    }

    /// Reduce what the app stores as the control domain to the bare apex
    /// the redirector lives under. The sign-in field takes the admin host
    /// verbatim (the config.json host; the bare control domain has no DNS
    /// by design), so `AppState.controlDomain` is usually
    /// `admin.<domain>` already -- prefixing `admin.` again produced
    /// `admin.admin.<domain>`, which nothing serves. The same reduction the
    /// extension applies to this exact value when it arrives over the App
    /// Group (`normalizeControlDomain` in controlDomain.ts): drop scheme
    /// and path, drop a leading `admin.`, lowercase, and demand something
    /// domain-shaped. Keep the two in step.
    static func normalizedControlDomain(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if value.hasPrefix("admin.") {
            value = String(value.dropFirst("admin.".count))
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        let labelOK: (Substring) -> Bool = { label in
            guard let first = label.first, let last = label.last else { return false }
            return first.isLetter || first.isNumber
                ? (last.isLetter || last.isNumber)
                    && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                : false
        }
        guard labels.count >= 2, labels.allSatisfy(labelOK) else { return nil }
        return value
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
    @MainActor public static func prime() {
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
    ///
    /// The target-form URL is built first either way: it is what validates
    /// the scheme and the control domain, and it is the fallback whenever
    /// the token form is unavailable (no App Group container in an
    /// unsigned build, say).
    @discardableResult
    @MainActor
    static func open(_ target: URL, controlDomain: String) -> Bool {
        guard let fragmentURL = redirectorURL(for: target, controlDomain: controlDomain) else {
            return false
        }
        var url = fragmentURL
        if fragmentForm(isSafariDefault: defaultBrowserIsSafari(), availability: isAvailable)
            == .token,
            let token = PrivateLinkTokenStore.mint(target),
            let tokenURL = redirectorURL(forToken: token, controlDomain: controlDomain) {
            url = tokenURL
        }
        NSWorkspace.shared.open(url)
        return true
    }
    #endif
}
