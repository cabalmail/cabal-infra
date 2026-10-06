import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `/list_folders` and `/folder_status` answering as the server last did.
struct FolderServerTransport: HTTPTransport {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let json: [String: Any]
        if path.hasSuffix("/list_folders") {
            json = ["folders": ["INBOX", "Archive", "Projects"], "sub_folders": ["INBOX", "Projects"]]
        } else {
            var status: [String: Any] = ["messages": 30, "unseen": 4, "uid_validity": 7, "uid_next": 31]
            // Like the Lambda, the flagged count only when asked for.
            if request.url?.query?.contains("flagged=1") == true { status["flagged"] = 2 }
            json = status
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (try JSONSerialization.data(withJSONObject: json), response)
    }
}

actor FolderConnectivity {
    var online = true
    func goOffline() { online = false }
    func goOnline() { online = true }
}

/// `FolderServerTransport` until the connection drops, then `UnreachableTransport`.
struct SwitchableFolderTransport: HTTPTransport {
    let connectivity: FolderConnectivity

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if await connectivity.online { return try await FolderServerTransport().perform(request) }
        return try await UnreachableTransport().perform(request)
    }
}

/// One test's on-disk world: the saved folder state an earlier online launch
/// left, and clients and list models over it.
@MainActor
final class OfflineFolderFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("offline-folder-state-app-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// What an earlier online launch left on disk: the folder list, and the
    /// counts of the two folders it opened.
    func savedState() async -> FolderStateCache {
        let cache = FolderStateCache(directory: root.appendingPathComponent("folders"))
        await cache.recordFolders(
            [
                Folder(path: "INBOX", isSubscribed: true),
                Folder(path: "Archive"),
                Folder(path: "Projects", isSubscribed: true),
            ],
            ifUnchangedSince: 0
        )
        await cache.recordStatus(FolderStatus(messages: 22, unseen: 2, flagged: 1), for: "INBOX", ifUnchangedSince: 0)
        await cache.recordStatus(FolderStatus(messages: 40, unseen: 5), for: "Projects", ifUnchangedSince: 0)
        await cache.recordStatus(FolderStatus(messages: 11, unseen: 3), for: "Archive", ifUnchangedSince: 0)
        return cache
    }

    func makeClient(
        folderState: FolderStateCache,
        transport: HTTPTransport = UnreachableTransport()
    ) throws -> CabalmailClient {
        let config = TestFixtures.makeConfiguration()
        let auth = NullAuthService()
        let api = URLSessionApiClient(configuration: config, authService: auth, transport: transport)
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: api,
            imapClient: ApiBackedImapClient(api: api, host: config.imapHost),
            addressCache: AddressCache(),
            envelopeCache: try EnvelopeCache(directory: root.appendingPathComponent("envelopes")),
            bodyCache: try MessageBodyCache(directory: root.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: root.appendingPathComponent("drafts")),
            outbox: try Outbox(directory: root.appendingPathComponent("outbox")),
            folderStateCache: folderState
        )
    }

    func cachedInbox(in client: CabalmailClient) async throws {
        let envelopes = (1...22).map { uid in
            TestFixtures.makeEnvelope(
                uid: UInt32(uid),
                flags: uid <= 20 ? [.seen] : []
            )
        }
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(
                uidValidity: 7,
                uidNext: 23,
                envelopes: Dictionary(uniqueKeysWithValues: envelopes.map { ($0.uid, $0) })
            ),
            for: "INBOX"
        )
    }

    func makeListModel(
        client: CabalmailClient, mailStore: MailSessionStore = AppState().mailStore
    ) -> MessageListViewModel {
        MessageListViewModel(
            folder: Folder(path: "INBOX", isSubscribed: true),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: mailStore
        )
    }
}

/// Polls `condition` until it holds, failing at the caller's line if it never does.
func eventually(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition never held", file: file, line: line)
}
