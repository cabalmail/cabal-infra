// The App Group handoff of a private-link target to the embedded Safari
// web extension (docs/1.x/browser-extension-plan.md, Phase 7 step 4).
//
// The redirector normally carries the target in its URL fragment, and the
// extension scrubs the redirector's history entry afterwards with
// `browser.history.deleteUrl`. WebKit implements no `history` API at all
// (#1765: `typeof browser.history` is `undefined` in a Safari web
// extension, and the declared permission is dropped as unrecognised), so
// on Safari that entry -- target and all -- stays in normal-window
// history, which is the one thing opening privately was meant to avoid.
//
// So for Safari the fragment carries an opaque token instead and the
// target rides through this store: the app mints a row here, the extension
// asks its native handler to resolve it (`resolve-private-link`), opens
// the target, then asks the handler to forget it. A history entry left
// behind then says that a private window was opened and no longer says
// what was opened.
//
// Rows are short-lived by construction -- the browser is launched within a
// second of minting and resolves immediately -- so they expire after
// `ttl` and the table is capped at `capacity`; the container must not
// become a browsing history of its own. The forget message is what retires
// a row in the normal case; the TTL is for the case where the extension
// never got to it (private-browsing access not granted, say), which is
// also why resolution is not destructive: the redirector tab is still
// open in that case and a reload must still work.
//
// Compiled into the app targets and the appex alike, following
// ExtensionControlDomainStore.swift.

import Foundation

enum PrivateLinkTokenStore {
    /// Same container and key namespace as ExtensionControlDomainStore.
    static let appGroupID = ExtensionControlDomainStore.appGroupID
    static let defaultsKey = "cabal.extension.private_link.rows"

    /// How long a minted row stays resolvable, and how many may coexist.
    static let ttl: TimeInterval = 120
    static let capacity = 8

    /// Row keys, spelled once: the table crosses into the appex as plist
    /// types, so it is `[token: [String: Any]]` rather than a Codable.
    static let urlKey = "url"
    static let mintedAtKey = "at"

    /// Nil when the suite name is unusable -- every operation then degrades
    /// to a no-op and `mint` declines, so the handoff falls back to the
    /// fragment form rather than breaking the menu row. Note this is rarer
    /// than it looks: an unentitled build gets a plain preferences domain
    /// rather than nil, which is why `mint` reads the row back before
    /// promising a token.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    typealias Table = [String: [String: Any]]

    // MARK: - Table algebra (pure; the testable half)

    /// A fresh token: 16 random bytes, hex. Lower-case hex is also what the
    /// redirector page and the extension match on to tell a token fragment
    /// from a URL one, so keep the alphabet in step with
    /// `PRIVATE_LINK_TOKEN` in extensions/shared/src/privateLink/handoff.ts.
    static func newToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// `table` with expired rows dropped and the newest `capacity` kept.
    static func pruned(_ table: Table, now: TimeInterval) -> Table {
        let live = table.filter { _, row in
            guard let minted = row[mintedAtKey] as? TimeInterval else { return false }
            return minted <= now && now - minted < ttl
        }
        guard live.count > capacity else { return live }
        let newest = live.sorted { lhs, rhs in
            (lhs.value[mintedAtKey] as? TimeInterval ?? 0)
                > (rhs.value[mintedAtKey] as? TimeInterval ?? 0)
        }
        return Table(uniqueKeysWithValues: newest.prefix(capacity).map { ($0.key, $0.value) })
    }

    /// `table` with `token` -> `target` added, pruned in the same pass.
    static func inserting(
        _ target: String, token: String, into table: Table, now: TimeInterval
    ) -> Table {
        var next = pruned(table, now: now)
        next[token] = [urlKey: target, mintedAtKey: now]
        return next
    }

    /// The target `token` resolves to, or nil when it is unknown or has
    /// expired. Non-destructive: `forget` retires a row (see the note on
    /// the reload path above).
    static func resolving(_ token: String, in table: Table, now: TimeInterval) -> String? {
        pruned(table, now: now)[token]?[urlKey] as? String
    }

    // MARK: - Container

    private static func read() -> Table {
        defaults?.dictionary(forKey: defaultsKey) as? Table ?? [:]
    }

    private static func write(_ table: Table) {
        guard let defaults else { return }
        if table.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(table, forKey: defaultsKey)
        }
    }

    /// Publish `target` for the extension. Returns the token to put in the
    /// fragment, or nil when there is no container to publish into -- the
    /// caller then uses the fragment form.
    static func mint(_ target: URL, now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        guard defaults != nil else { return nil }
        let token = newToken()
        write(inserting(target.absoluteString, token: token, into: read(), now: now))
        // Prove the row is actually readable before promising the token:
        // a container the entitlement does not cover reads back empty.
        guard resolve(token, now: now) != nil else { return nil }
        return token
    }

    /// Resolve a token for the extension's native handler.
    static func resolve(
        _ token: String, now: TimeInterval = Date().timeIntervalSince1970
    ) -> String? {
        let table = read()
        let live = pruned(table, now: now)
        if live.count != table.count { write(live) }
        return live[token]?[urlKey] as? String
    }

    /// Retire a row once the extension has opened it.
    static func forget(_ token: String, now: TimeInterval = Date().timeIntervalSince1970) {
        var table = pruned(read(), now: now)
        table.removeValue(forKey: token)
        write(table)
    }
}
