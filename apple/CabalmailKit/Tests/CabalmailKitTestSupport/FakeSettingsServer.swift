import Foundation
import CabalmailKit

/// The server half of the settings sync and of the feed queue's state
/// calls, answered over HTTP for a client from `CabalmailClient.make(...)`
/// (`transport`). It does what stage does with them:
///
/// - `GET /get_preferences` answers the `app` map it holds and the row's
///   `version`, a count of the writes it has taken;
/// - `PUT /set_preferences` merges the `app` map it is sent, per key, and
///   counts the version up by one. A request that names the version it was
///   built on (`expectedVersion`) is written only if the row is still at
///   it; otherwise nothing is written and the answer is a 409 holding the
///   row as it is. A request that names none is always written, as a
///   build that predates the version sends it. It refuses the whole map,
///   writing nothing (400 "Invalid value for app."), when a flag's name or
///   the signature breaks stage's rules: a name of 1 to 32 code points, a
///   signature of at most 2,000, neither holding a control character (the
///   signature may hold newlines and tabs). The check is written out here
///   from `set_preferences`, not borrowed from the Kit's `ServerTextRules`,
///   so a test of those rules against this server has something to fail on;
/// - `POST /rss_set_item_state` refuses the whole call, writing nothing,
///   when an entry adds a slot that the held `flag_palette` does not list
///   (400 `flag_not_in_palette` naming the slots), and otherwise records it.
///
/// Any of the three can be made to fail the way an offline device's
/// requests do (`fail(_:)`), or be held until released: before the server
/// looks at it (`holdNext(_:)`), or after it has answered and before the
/// answer arrives (`holdNextAnswer(_:)`). `refuseSettings(_:)` makes
/// `/set_preferences` refuse every map and `refuseNextSettings()` the next
/// one; `predatesTheVersion()` makes the
/// server one that neither answers nor checks a version;
/// `anotherDeviceWrites(_:)` is a second device's write.
/// Every request is recorded in order, with how it went (`calls`), and
/// every map `/set_preferences` was sent (`sentMaps`).
public actor FakeSettingsServer {
    public enum Endpoint: String, Sendable, CaseIterable {
        case getPreferences = "/get_preferences"
        case setPreferences = "/set_preferences"
        case setItemState = "/rss_set_item_state"
    }

    /// How a request was answered. `stale`: a write built on an older row
    /// (the 409).
    public enum Outcome: String, Sendable { case offline, refused, stale, accepted }

    /// One request and how it was answered.
    public struct Call: Equatable, Sendable, CustomStringConvertible {
        public let endpoint: Endpoint
        public let outcome: Outcome
        public var description: String { "\(endpoint.rawValue) \(outcome.rawValue)" }
    }

    /// The `app` map as stored.
    public private(set) var app: [String: String]
    /// How many writes the row has taken.
    public private(set) var version: Int
    public private(set) var calls: [Call] = []
    /// The `app` map of every `/set_preferences` request that arrived,
    /// however it was answered.
    public private(set) var sentMaps: [[String: String]] = []
    /// The `expectedVersion` of each of those requests, nil when it named
    /// none.
    public private(set) var sentVersions: [Int?] = []
    /// The slots each accepted `/rss_set_item_state` added, one set a call.
    public private(set) var acceptedFlagAdds: [Set<String>] = []
    private var failing: Set<Endpoint> = []
    private var refusingSettings = false
    private var refusingNextSettings = false
    private var movingOn = false
    private var answersVersion = true
    private var holdArmed: Set<Endpoint> = []
    private var answerHoldArmed: Set<Endpoint> = []
    private var held: [Endpoint: CheckedContinuation<Void, Never>] = [:]

    /// A row holding `app`. It has taken one write when it holds anything.
    public init(app: [String: String] = [:]) {
        self.app = app
        self.version = app.isEmpty ? 0 : 1
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

    /// Makes this a server from before the version: it answers none and
    /// writes every request whatever `expectedVersion` it names.
    public func predatesTheVersion() {
        answersVersion = false
    }

    /// Makes another device write just ahead of every `/set_preferences`
    /// request from now on, so each one that names a version finds the row
    /// moved on.
    public func keepsMovingOn() {
        movingOn = true
    }

    /// A write from another device: merged per key and counted, as any
    /// write is.
    public func anotherDeviceWrites(_ changes: [String: String]) {
        app.merge(changes) { _, new in new }
        version += 1
    }

    /// Makes `/set_preferences` refuse the next map it is sent, and only
    /// that one.
    public func refuseNextSettings() {
        refusingNextSettings = true
    }

    /// Lets every endpoint through again.
    public func reconnect() {
        failing.removeAll()
    }

    /// Parks the next request to `endpoint` until `release(_:)`, before the
    /// server has looked at it.
    public func holdNext(_ endpoint: Endpoint) {
        holdArmed.insert(endpoint)
    }

    /// Parks the next request to `endpoint` until `release(_:)`, after the
    /// server has answered it: the answer is of the row as it was then,
    /// and arrives late.
    public func holdNextAnswer(_ endpoint: Endpoint) {
        answerHoldArmed.insert(endpoint)
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
        let answer = try answer(endpoint, request, body)
        if answerHoldArmed.remove(endpoint) != nil {
            await withCheckedContinuation { held[endpoint] = $0 }
        }
        return answer
    }

    /// The row as `/get_preferences` answers it.
    private var row: [String: Any] {
        answersVersion ? ["app": app, "version": version] : ["app": app]
    }

    private func answer(_ endpoint: Endpoint, _ request: URLRequest, _ body: [String: Any]?) throws
        -> (Data, HTTPURLResponse) {
        switch endpoint {
        case .getPreferences:
            calls.append(Call(endpoint: endpoint, outcome: .accepted))
            return try reply(request, 200, row)
        case .setPreferences:
            let sent = body?["app"] as? [String: String] ?? [:]
            let expected = body?["expectedVersion"] as? Int
            sentMaps.append(sent)
            sentVersions.append(expected)
            let refusingThisOne = refusingNextSettings
            refusingNextSettings = false
            guard !refusingSettings, !refusingThisOne, Self.takes(sent) else {
                calls.append(Call(endpoint: endpoint, outcome: .refused))
                return try reply(request, 400, ["Error": "Invalid value for app."])
            }
            if movingOn { version += 1 }
            if answersVersion, let expected, expected != version {
                calls.append(Call(endpoint: endpoint, outcome: .stale))
                return try reply(request, 409, row.merging(
                    ["Error": "Preferences changed on another device; merge and send again."]
                ) { current, _ in current })
            }
            app.merge(sent) { _, new in new }
            version += 1
            calls.append(Call(endpoint: endpoint, outcome: .accepted))
            return try reply(request, 200, answersVersion ? ["app": sent, "version": version] : ["app": sent])
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
