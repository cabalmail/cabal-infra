// Last-session persistence for AppState, split from AppState.swift when
// the control-domain mirror for the embedded Safari extension pushed that
// file past the 500-line lint cap. Cohesive on its own: everything here is
// the "remember where I signed in" surface.

import Foundation

// MARK: - Persisted last-session fields

extension AppState {
    /// Last-used control domain, persisted so repeat launches skip re-entry.
    /// Mirrored into the shared App Group for the embedded Safari web
    /// extension, which asks its native handler for it so the user never
    /// types the server twice (ExtensionControlDomainStore).
    var controlDomain: String {
        get { UserDefaults.standard.string(forKey: "cabalmail.controlDomain") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "cabalmail.controlDomain")
            ExtensionControlDomainStore.publish(newValue)
        }
    }

    /// Last-used username, same persistence rationale. Passwords are never
    /// persisted here — `CognitoAuthService` holds them in the data-protection
    /// keychain via `KeychainSecureStore`.
    var lastUsername: String {
        get { UserDefaults.standard.string(forKey: "cabalmail.lastUsername") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabalmail.lastUsername") }
    }
}
