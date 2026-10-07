// The App Group handoff of the control domain to the embedded Safari web
// extension (docs/1.x/browser-extension-plan.md, OQ9 resolution).
//
// The mail app publishes the domain the user typed at sign-in; the web
// extension's background asks its native handler for it (a
// `sendNativeMessage` round-trip -- see
// extensions/shared/src/config/controlDomain.ts), so the user never types
// the server twice. It lives in CabalmailShared because both sides use it:
// the app through the Kit, and both Safari web extensions, which link this
// module rather than all of CabalmailKit.

import Foundation

public enum ExtensionControlDomainStore {
    /// In the same `cabal.*` key namespace as `PushHandoff.apiURLDefaultsKey`.
    static let defaultsKey = "cabal.extension.control_domain"

    /// Nil only when the suite name is unusable, and every operation then
    /// degrades to a no-op, same posture as PushEnrichmentStore: the handoff
    /// must never break sign-in. An unentitled build (unsigned, the test
    /// runner) gets a plain preferences domain instead, which no extension
    /// reads.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    /// Publish the domain for the appex; empty or whitespace clears it.
    public static func publish(_ controlDomain: String) {
        let trimmed = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults?.removeObject(forKey: defaultsKey)
        } else {
            defaults?.set(trimmed.lowercased(), forKey: defaultsKey)
        }
    }

    /// The published domain, or nil when the app has not signed in anywhere.
    public static func read() -> String? {
        guard let value = defaults?.string(forKey: defaultsKey), !value.isEmpty else {
            return nil
        }
        return value
    }
}
