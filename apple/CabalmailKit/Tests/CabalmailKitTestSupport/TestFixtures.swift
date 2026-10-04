import Foundation
import CabalmailKit

/// Fixture factories that need only Kit types. The app-layer bundle adds its
/// view-model factories (`makeModel`, `makeComposeModel`) in an extension of
/// this enum, since those types live in the app module.
public enum TestFixtures {
    public static func makeConfiguration() -> Configuration {
        Configuration(
            controlDomain: "cabalmail.example",
            domains: [MailDomain(domain: "cabalmail.example")],
            invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
            cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
        )
    }

    /// Full client around the fake IMAP transport. Caches land in a
    /// per-invocation temp directory (the bulk paths prune them; empty
    /// caches make that a no-op).
    public static func makeClient(
        imap: FakeImapClient,
        transport: HTTPTransport = NullHTTPTransport(),
        addressCache: AddressCache = AddressCache()
    ) throws -> CabalmailClient {
        let config = makeConfiguration()
        let auth = NullAuthService()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-tests-\(UUID().uuidString)")
        return CabalmailClient(
            configuration: config,
            authService: auth,
            apiClient: URLSessionApiClient(
                configuration: config,
                authService: auth,
                transport: transport
            ),
            imapClient: imap,
            addressCache: addressCache,
            envelopeCache: try EnvelopeCache(directory: tmp.appendingPathComponent("e")),
            bodyCache: try MessageBodyCache(directory: tmp.appendingPathComponent("b")),
            draftStore: try DraftStore(directory: tmp.appendingPathComponent("d")),
            outbox: try Outbox(directory: tmp.appendingPathComponent("o"))
        )
    }

    public static func makeEnvelope(
        uid: UInt32,
        flags: Set<Flag> = [],
        messageId: String? = nil,
        subject: String? = nil
    ) -> Envelope {
        Envelope(
            uid: uid,
            messageId: messageId,
            subject: subject ?? "Subject \(uid)",
            from: [EmailAddress(name: "Sender", mailbox: "sender\(uid)", host: "example.com")],
            flags: flags
        )
    }
}
