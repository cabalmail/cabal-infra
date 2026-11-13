import Foundation
import CabalmailKit

/// The server half of the settings sync and of the feed queue's state
/// calls, answered over HTTP for a client from `CabalmailClient.make(...)`
/// (`transport`). It does what stage does with them:
///
/// - `GET /get_preferences` answers the `app` map it holds;
/// - `PUT /set_preferences` merges the `app` map it is sent, per key, or
///   refuses the whole map, writing nothing (400 "Invalid value for app."),
///   when a flag's name or the signature breaks stage's rules: a name of 1
///   to 32 code points, a signature of at most 2,000, neither holding a
///   control character (the signature may hold newlines and tabs). The
///   check is written out here from `set_preferences`, not borrowed from
///   the Kit's `ServerTextRules`, so a test of those rules against this
///   server has something to fail on;
/// - `POST /rss_set_item_state` refuses the whole call, writing nothing,
///   when an entry adds a slot that the held `flag_palette` does not list
///   (400 `flag_not_in_palette` naming the slots), and otherwise records it.
///
/// Any of the three can be made to fail the way an offline device's
/// requests do (`fail(_:)`), or be held until released (`holdNext(_:)`);
/// `refuseSettings(_:)` makes `/set_preferences` refuse every map.
/// Every request is recorded in order, with how it went (`calls`).
public actor FakeSettingsServer {
    public enum Endpoint: String, Sendable, CaseIterable {
        case getPreferences = "/get_preferences"
        case setPreferences = "/set_preferences"
        case setItemState = "/rss_set_item_state"
    }

    /// How a request was answered.
    public enum Outcome: String, Sendable { case offline, refused, accepted }

    /// One request and how it was answered.
    public struct Call: Equatable, Sendable, CustomStringConvertible {
        public let endpoint: Endpoint
        public let outcome: Outcome
        public var description: String { "\(endpoint.rawValue) \(outcome.rawValue)" }
    }

    /// The `app` map as stored.
    public private(set) var app: [String: String]
    public private(set) var calls: [Call] = []
    /// The slots each accepted `/rss_set_item_state` added, one set a call.
    public private(set) var acceptedFlagAdds: [Set<String>] = []
    private var failing: Set<Endpoint> = []
    private var refusingSettings = false
    private var holdArmed: Set<Endpoint> = []
    private var held: [Endpoint: CheckedContinuation<Void, Never>] = [:]

    public init(app: [String: String] = [:]) {
        self.app = app
    }

    /// The transport to hand `CabalmailClient.make(...)`.
    public nonisolated var transport: HTTPTransport {
        ScriptedHTTPTransport { [self] request in try await handle(request) }
    }

    /// Makes `endpoint` fail, or stop failing, as an offline device's
    /// requests do.
    public func fail(_ endpoint: Endpoint, _ failing: Bool = true) {
        if failing { self.failing.insert(endpoint) } else { self.failing.remove(endpoint) }
    }

    /// Makes `/set_preferences` refuse every map, or stop refusing, as
    /// stage does a map that breaks one of its checks.
    public func refuseSettings(_ refusing: Bool = true) {
        refusingSettings = refusing
    }

    /// Lets every endpoint through again.
    public func reconnect() {
        failing.removeAll()
    }

    /// Parks the next request to `endpoint` until `release(_:)`.
    public func holdNext(_ endpoint: Endpoint) {
        holdArmed.insert(endpoint)
    }

    public func isHolding(_ endpoint: Endpoint) -> Bool {
        held[endpoint] != nil
    }

    public func release(_ endpoint: Endpoint) {
        held.removeValue(forKey: endpoint)?.resume()
    }

    /// The slots of the stored `flag_palette`.
    public var paletteSlots: Set<String> {
        Set(app["flag_palette"].flatMap(FlagPalette.decode)?.map(\.slot) ?? [])
    }

    public func calls(to endpoint: Endpoint) -> [Call] {
        calls.filter { $0.endpoint == endpoint }
    }

    private func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        guard let endpoint = Endpoint.allCases.first(where: { path.hasSuffix($0.rawValue) }) else {
            throw CabalmailError.transport("FakeSettingsServer: unexpected request to \(path)")
        }
        if holdArmed.remove(endpoint) != nil {
            await withCheckedContinuation { held[endpoint] = $0 }
        }
        if failing.contains(endpoint) {
            calls.append(Call(endpoint: endpoint, outcome: .offline))
            throw CabalmailError.network("The Internet connection appears to be offline.")
        }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        switch endpoint {
        case .getPreferences:
            calls.append(Call(endpoint: endpoint, outcome: .accepted))
            return try reply(request, 200, ["app": app])
        case .setPreferences:
            let sent = body?["app"] as? [String: String] ?? [:]
            guard !refusingSettings, Self.takes(sent) else {
                calls.append(Call(endpoint: endpoint, outcome: .refused))
                return try reply(request, 400, ["Error": "Invalid value for app."])
            }
            app.merge(sent) { _, new in new }
            calls.append(Call(endpoint: endpoint, outcome: .accepted))
            return try reply(request, 200, ["status": "ok"])
        case .setItemState:
            let items = body?["items"] as? [[String: Any]] ?? []
            let adding = items.reduce(into: Set<String>()) { $0.formUnion($1["add_flags"] as? [String] ?? []) }
            let refused = adding.subtracting(paletteSlots).sorted()
            guard refused.isEmpty else {
                calls.append(Call(endpoint: endpoint, outcome: .refused))
                return try reply(request, 400, [
                    "Error": "Not a flag in the palette: \(refused.joined(separator: ", ")).",
                    "code": "flag_not_in_palette",
                    "flags": refused,
                ])
            }
            calls.append(Call(endpoint: endpoint, outcome: .accepted))
            acceptedFlagAdds.append(adding)
            return try reply(request, 200, ["updated": items.count])
        }
    }

    /// Stage's checks of the typed values (`_validate_app`), counted as
    /// Python's `len()` counts: in code points.
    private static func takes(_ sent: [String: String]) -> Bool {
        func control(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 32 || scalar.value == 127 }
        if let signature = sent["signature"] {
            let scalars = signature.unicodeScalars
            guard scalars.count <= 2000, !scalars.contains(where: { control($0) && $0 != "\n" && $0 != "\t" })
            else { return false }
        }
        if let palette = sent["flag_palette"] {
            guard let data = palette.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return false }
            for entry in entries {
                guard let label = entry["label"] as? String,
                      (1...32).contains(label.unicodeScalars.count),
                      !label.unicodeScalars.contains(where: control)
                else { return false }
            }
        }
        return true
    }

    private func reply(_ request: URLRequest, _ status: Int, _ body: [String: Any]) throws
        -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}
