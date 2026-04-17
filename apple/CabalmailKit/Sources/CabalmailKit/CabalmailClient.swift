import Foundation

/// Top-level client that owns the auth session and API surface.
///
/// Phase 1 placeholder — Phase 3 fleshes out `AuthService` and `ApiClient` and wires them in here.
public actor CabalmailClient {
    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }
}
