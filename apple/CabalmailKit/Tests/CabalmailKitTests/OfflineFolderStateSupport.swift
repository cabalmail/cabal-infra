import XCTest
@testable import CabalmailKit

/// One test's on-disk world for the folder-state tests: `launch` builds a
/// fresh client over the same directory each time, standing in for a relaunch.
final class FolderStateHarness {
    static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
    )

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("offline-folder-state-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// One launch: a new client and a new cache over the shared directory,
    /// as `CabalmailClient.make` wires them. `persistent: false` builds a
    /// client with no saved folder state, as every launch had before.
    func launch(_ network: FolderNetwork, persistent: Bool = true) throws -> CabalmailClient {
        let auth = StubAuthService()
        let api = URLSessionApiClient(
            configuration: Self.configuration,
            authService: auth,
            transport: ScriptedHTTPTransport { request in try await network.respond(to: request) }
        )
        return CabalmailClient(
            configuration: Self.configuration,
            authService: auth,
            apiClient: api,
            imapClient: ApiBackedImapClient(api: api, host: Self.configuration.imapHost),
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: root.appendingPathComponent("envelopes")),
            bodyCache: try MessageBodyCache(directory: root.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: root.appendingPathComponent("drafts")),
            outbox: try Outbox(directory: root.appendingPathComponent("outbox")),
            folderStateCache: persistent
                ? FolderStateCache(directory: root.appendingPathComponent("folders"))
                : FolderStateCache()
        )
    }

    /// An online launch that loads the sidebar and opens two folders.
    func onlineSession(_ network: FolderNetwork) async throws -> CabalmailClient {
        let client = try launch(network)
        _ = try await client.folders()
        _ = try await client.folderStatus(path: "INBOX", flagged: true)
        _ = try await client.folderStatus(path: "Projects/Cabal", flagged: true)
        return client
    }
}

/// Fails unless `call` throws the `.network` error an unreachable server gives.
func assertUnreachable(
    _ call: () async throws -> Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await call()
        XCTFail("expected the offline fetch to throw", file: file, line: line)
    } catch let error as CabalmailError {
        guard case .network = error else {
            return XCTFail("expected .network, got \(error)", file: file, line: line)
        }
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}

/// What the fake `/folder_status` reports for one folder.
struct FolderCounts {
    let messages: Int
    let unseen: Int
    let flagged: Int
}

/// Stands in for the network: `/list_folders` and `/folder_status`
/// answer from the properties below while online, fail like URLSession
/// does with no connection otherwise, and answer `refusal` with a server
/// error when set. `holdNextStatus` and `holdNextList` park the next
/// `/folder_status` or `/list_folders` after it has read its answer, until
/// `releaseStatus()` or `releaseList()`.
actor FolderNetwork {
    var online = true
    var refusal: Int?
    var folders = ["INBOX", "Archive", "Projects/Cabal"]
    var subscribed = ["INBOX", "Projects/Cabal"]
    var status: [String: FolderCounts] = [
        "INBOX": FolderCounts(messages: 22, unseen: 2, flagged: 1),
        "Projects/Cabal": FolderCounts(messages: 40, unseen: 5, flagged: 3),
    ]
    var holdNextStatus = false
    var holdNextList = false
    private var held: CheckedContinuation<Void, Never>?

    var isHoldingStatus: Bool { held != nil }
    var isHoldingList: Bool { held != nil }

    func set(online: Bool) { self.online = online }
    func set(refusal: Int?) { self.refusal = refusal }
    func set(folders: [String], subscribed: [String]) {
        self.folders = folders
        self.subscribed = subscribed
    }
    func set(status path: String, _ counts: FolderCounts) {
        status[path] = counts
    }
    func set(holdNextStatus: Bool) { self.holdNextStatus = holdNextStatus }
    func set(holdNextList: Bool) { self.holdNextList = holdNextList }

    func releaseList() { releaseStatus() }

    func releaseStatus() {
        held?.resume()
        held = nil
    }

    func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard online else {
            throw CabalmailError.network("The Internet connection appears to be offline.")
        }
        if let refusal {
            return (Data(#"{"status":"boom"}"#.utf8), Self.response(request, status: refusal))
        }
        let path = request.url?.path ?? ""
        if path.hasSuffix("/list_folders") {
            let body = try JSONSerialization.data(withJSONObject: ["folders": folders, "sub_folders": subscribed])
            if holdNextList {
                holdNextList = false
                await withCheckedContinuation { held = $0 }
            }
            return (body, Self.response(request, status: 200))
        }
        guard path.hasSuffix("/folder_status"),
              let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false),
              let folder = components.queryItems?.first(where: { $0.name == "folder" })?.value,
              let counts = status[folder] else {
            return (Data("{}".utf8), Self.response(request, status: 200))
        }
        let wantsFlagged = components.queryItems?.contains { $0.name == "flagged" } == true
        var json: [String: Any] = ["messages": counts.messages, "unseen": counts.unseen,
                                   "uid_validity": 7, "uid_next": counts.messages + 1]
        if wantsFlagged { json["flagged"] = counts.flagged }
        let body = try JSONSerialization.data(withJSONObject: json)
        if holdNextStatus {
            holdNextStatus = false
            await withCheckedContinuation { held = $0 }
        }
        return (body, Self.response(request, status: 200))
    }

    private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
