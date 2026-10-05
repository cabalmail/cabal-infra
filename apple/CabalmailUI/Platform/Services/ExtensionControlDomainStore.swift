// The App Group handoff of the control domain to the embedded Safari web
// extension (docs/1.x/browser-extension-plan.md, OQ9 resolution).
//
// The mail app publishes the domain the user typed at sign-in; the web
// extension's background asks its native handler for it (a
// `sendNativeMessage` round-trip -- see
// extensions/shared/src/config/controlDomain.ts), so the user never types
// the server twice. Compiled into the app targets and the appex alike,
// following the shared-single-file pattern of WatchSessionBridge.swift --
// pulling all of CabalmailKit into the appex for two strings would be
// disproportionate.

import Foundation

enum ExtensionControlDomainStore {
    /// Shared with the NSE and (now) the web-extension appex; declared in
    /// every participating target's entitlements.
    static let appGroupID = "group.com.cabalmail.Cabalmail"
    /// Same value namespace as PushEnrichmentStore's `cabal.push.*` keys.
    static let defaultsKey = "cabal.extension.control_domain"

    /// Nil when the shared container is unavailable (unsigned builds, the
    /// test runner) -- every operation degrades to a no-op, same posture as
    /// PushEnrichmentStore: the handoff must never break sign-in.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Publish the domain for the appex; empty or whitespace clears it.
    static func publish(_ controlDomain: String) {
        let trimmed = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults?.removeObject(forKey: defaultsKey)
        } else {
            defaults?.set(trimmed.lowercased(), forKey: defaultsKey)
        }
    }

    /// The published domain, or nil when the app has not signed in anywhere.
    static func read() -> String? {
        guard let value = defaults?.string(forKey: defaultsKey), !value.isEmpty else {
            return nil
        }
        return value
    }
}
