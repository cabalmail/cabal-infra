import XCTest
import CabalmailKit
@testable import Cabalmail

/// Compose opened without a connection must still offer the addresses the
/// account can send from, or nothing can be queued for the outbox unless a
/// default From happens to be set. The list comes from the copy an earlier
/// online fetch saved; it can be out of date, so it must not settle whether
/// the default From still exists.
@MainActor
final class ComposeOfflineFromTests: XCTestCase {
    private struct OfflineTransport: HTTPTransport {
        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            throw CabalmailError.network("The Internet connection appears to be offline.")
        }
    }

    /// `/list` answering with `addresses`, in the Lambda's `{"Items": …}` shape.
    private struct ListTransport: HTTPTransport {
        let addresses: [Address]

        func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let items = addresses.map {
                #"{"address":"\#($0.address)","subdomain":"\#($0.subdomain)","tld":"\#($0.tld)"}"#
            }
            let body = Data(#"{"Items":[\#(items.joined(separator: ","))]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, response)
        }
    }

    private let saved = [
        Address(address: "shop@s.cabalmail.example", subdomain: "s", tld: "cabalmail.example"),
        Address(address: "pen-pal@p.cabalmail.example", subdomain: "p", tld: "cabalmail.example"),
    ]

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-offline-from-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// This launch's cache, reading what an earlier launch's fetch saved.
    private func cacheWithSavedList() async -> AddressCache {
        let directory = root.appendingPathComponent("addresses")
        await AddressCache(directory: directory).set(saved)
        return AddressCache(directory: directory)
    }

    private func makeModel(
        cache: AddressCache,
        defaultFrom: String? = nil,
        transport: HTTPTransport = OfflineTransport()
    ) throws -> (ComposeViewModel, Preferences) {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.defaultFromAddress = defaultFrom
        let model = ComposeViewModel(
            client: try TestFixtures.makeClient(
                imap: FakeImapClient(), transport: transport, addressCache: cache
            ),
            draftStore: try DraftStore(directory: root.appendingPathComponent("drafts")),
            preferences: preferences,
            onClose: {}
        )
        return (model, preferences)
    }

    func testOfflineComposeOffersTheSavedAddressesAndCanSend() async throws {
        let (model, _) = try makeModel(cache: await cacheWithSavedList())

        await model.refreshAddresses()

        XCTAssertEqual(model.availableAddresses.map(\.address), saved.map(\.address))
        XCTAssertNil(model.errorMessage)
        model.toText = "friend@elsewhere.example"
        model.subject = "Written offline"
        XCTAssertFalse(model.canSend, "no From picked yet, and no default to fall back on")
        model.fromAddress = "pen-pal@p.cabalmail.example"
        XCTAssertTrue(model.canSend)
    }

    /// Negative control: the memory-only cache every launch had before. An
    /// offline launch got no list, so with no default From there was nothing
    /// to send from and Send could never be enabled.
    func testMemoryOnlyCacheLeavesOfflineComposeNothingToSendFrom() async throws {
        let (model, _) = try makeModel(cache: AddressCache())

        await model.refreshAddresses()

        XCTAssertTrue(model.availableAddresses.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        model.toText = "friend@elsewhere.example"
        model.subject = "Written offline"
        XCTAssertFalse(model.canSend)
    }

    /// A saved list can predate an address made on another device and then
    /// set as the default there. Treating the saved list as complete would
    /// empty the From field and clear the default, and the cleared default
    /// would reach the server once the connection came back.
    func testSavedListKeepsADefaultFromItDoesNotList() async throws {
        let (model, preferences) = try makeModel(
            cache: await cacheWithSavedList(),
            defaultFrom: "made-elsewhere@n.cabalmail.example"
        )

        await model.refreshAddresses()

        XCTAssertEqual(preferences.defaultFromAddress, "made-elsewhere@n.cabalmail.example")
        XCTAssertEqual(model.fromAddress, "made-elsewhere@n.cabalmail.example")
    }

    /// Control for the test above: a list the server has just returned is
    /// complete, so a default From it lacks is still dropped.
    func testFreshListStillDropsADefaultFromItDoesNotList() async throws {
        let (model, preferences) = try makeModel(
            cache: AddressCache(directory: root.appendingPathComponent("addresses")),
            defaultFrom: "revoked@r.cabalmail.example",
            transport: ListTransport(addresses: saved)
        )

        await model.refreshAddresses()

        XCTAssertEqual(model.availableAddresses.map(\.address), saved.map(\.address))
        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertNil(model.fromAddress)
    }

    // MARK: - Replies

    /// A message a correspondent sent to the address the user gave them.
    private let sentToPenPal = Envelope(
        uid: 7,
        subject: "Hello",
        from: [EmailAddress(name: "Friend", mailbox: "friend", host: "elsewhere.example")],
        to: [EmailAddress(name: nil, mailbox: "pen-pal", host: "p.cabalmail.example")]
    )

    /// The reply seed `MessageDetailView.beginCompose` builds, offline.
    private func offlineReplySeed(cache: AddressCache) async throws -> Draft {
        let client = try TestFixtures.makeClient(
            imap: FakeImapClient(), transport: OfflineTransport(), addressCache: cache
        )
        return ReplyBuilder.build(
            from: sentToPenPal,
            body: "Hi",
            mode: .reply,
            userAddresses: await MessageDetailView.replyAddresses(client: client),
            sourceFolder: "INBOX"
        )
    }

    /// The reply's From is the original's addressee when the account owns
    /// it. Offline, ownership comes from the saved list.
    func testOfflineReplyComesFromTheAddressTheMessageWasSentTo() async throws {
        let seed = try await offlineReplySeed(cache: await cacheWithSavedList())
        XCTAssertEqual(seed.fromAddress, "pen-pal@p.cabalmail.example")
    }

    /// Negative control: with the memory-only cache an offline reply matched
    /// no owned address, so compose filled From with the default instead.
    func testMemoryOnlyCacheLeavesAnOfflineReplyWithoutItsFrom() async throws {
        let seed = try await offlineReplySeed(cache: AddressCache())
        XCTAssertNil(seed.fromAddress)
    }
}
