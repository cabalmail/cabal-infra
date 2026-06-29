import Foundation

/// Cross-client navigation cursor flows, split out of `CabalmailClient.swift`
/// to keep the actor's primary body under SwiftLint's type_body_length cap.
/// Same-module extension; everything here runs on the actor as usual.
extension CabalmailClient {
    /// Loads the saved navigation cursor (last folder/message/scroll), or nil
    /// if none exists. The app restores from this on launch and reconciles
    /// against it on foreground to offer the cross-device jump.
    public func navState() async throws -> NavState? {
        try await apiClient.loadNavState()
    }

    /// Persists the navigation cursor server-side, where the other clients
    /// read it. Only the currently-active client writes, so this replaces the
    /// whole cursor rather than merging.
    public func setNavState(_ state: NavState) async throws {
        try await apiClient.saveNavState(state)
    }
}
