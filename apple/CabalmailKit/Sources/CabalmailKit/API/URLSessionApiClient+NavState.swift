import Foundation

// MARK: - Navigation cursor

extension URLSessionApiClient {
    public func loadNavState() async throws -> NavState? {
        let request = try await get("/get_nav_state")
        let data = try await send(request, expectedStatuses: 200..<300)
        // An empty `{}` (no cursor saved yet) fails the `folder`-required
        // decode, which reads the same as "nothing to restore".
        return try? JSONDecoder().decode(NavState.self, from: data)
    }

    public func saveNavState(_ state: NavState) async throws {
        let request = try await put("/set_nav_state", json: state.requestBody)
        _ = try await send(request, expectedStatuses: 200..<300)
    }
}
