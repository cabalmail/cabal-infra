import Foundation

/// SMTP submission client. Connects to the Cabalmail SMTP-out tier, AUTHs
/// with the Cognito credentials held by `AuthService`, and sends a
/// pre-built RFC 5322 payload via `DATA`.
///
/// Per the Phase 3 plan, implementation is hand-rolled rather than adding
/// an external SMTP dependency. Default security is implicit TLS on port
/// 465 — `NetworkByteStream` connects with TLS from the start, avoiding
/// the `NWConnection`-unfriendly STARTTLS upgrade. The submission listener
/// in `terraform/infra/modules/elb/main.tf` binds both 465 and 587 so
/// either port is available.
public protocol SmtpClient: Sendable {
    func send(_ message: OutgoingMessage) async throws
}

public protocol SmtpConnectionFactory: Sendable {
    func makeConnection() async throws -> ByteStream
}

#if canImport(Network)
public struct NetworkSmtpConnectionFactory: SmtpConnectionFactory {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 465) {
        self.host = host
        self.port = port
    }

    public func makeConnection() async throws -> ByteStream {
        let stream = NetworkByteStream(host: host, port: port, useTLS: true)
        try await stream.start()
        return stream
    }
}
#endif

public actor LiveSmtpClient: SmtpClient {
    private let factory: SmtpConnectionFactory
    private let authService: AuthService
    private let clientHostname: String

    public init(factory: SmtpConnectionFactory, authService: AuthService, clientHostname: String = "cabalmail.local") {
        self.factory = factory
        self.authService = authService
        self.clientHostname = clientHostname
    }

    public func send(_ message: OutgoingMessage) async throws {
        let stream = try await factory.makeConnection()
        let connection = SmtpConnection(stream: stream)
        do {
            try await runSubmission(connection: connection, message: message)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    private func runSubmission(connection: SmtpConnection, message: OutgoingMessage) async throws {
        try await expect(connection, code: 220)
        try await ehlo(connection)
        try await authenticate(connection)
        try await sender(connection, address: message.from)
        let recipients = message.to + message.cc + message.bcc
        for recipient in recipients {
            try await connection.writeLine("RCPT TO:<\(recipient.mailbox)@\(recipient.host)>")
            let response = try await connection.readResponse()
            guard (200..<300).contains(response.code) else {
                throw CabalmailError.smtpCommandFailed(
                    code: response.code,
                    detail: response.lines.joined(separator: " ")
                )
            }
        }
        try await connection.writeLine("DATA")
        try await expect(connection, code: 354)
        let messageID = message.messageId ?? newMessageID(from: message.from)
        let payload = MessageBuilder.build(message, messageID: messageID)
        try await connection.writeDataPayload(payload)
        try await expect(connection, code: 250)
        try await connection.writeLine("QUIT")
        _ = try? await connection.readResponse()
    }

    // MARK: - Internals

    private func ehlo(_ connection: SmtpConnection) async throws {
        try await connection.writeLine("EHLO \(clientHostname)")
        let response = try await connection.readResponse()
        guard response.code == 250 else {
            throw CabalmailError.smtpCommandFailed(
                code: response.code,
                detail: response.lines.joined(separator: " ")
            )
        }
    }

    private func authenticate(_ connection: SmtpConnection) async throws {
        let creds = try await authService.currentImapCredentials()
        // AUTH PLAIN format: base64(\0 user \0 pass)
        var authPayload = Data()
        authPayload.append(0)
        authPayload.append(contentsOf: creds.username.utf8)
        authPayload.append(0)
        authPayload.append(contentsOf: creds.password.utf8)
        let base64 = authPayload.base64EncodedString()
        try await connection.writeLine("AUTH PLAIN \(base64)")
        let response = try await connection.readResponse()
        guard response.code == 235 else {
            if response.code == 535 {
                throw CabalmailError.invalidCredentials
            }
            throw CabalmailError.smtpCommandFailed(
                code: response.code,
                detail: response.lines.joined(separator: " ")
            )
        }
    }

    private func sender(_ connection: SmtpConnection, address: EmailAddress) async throws {
        try await connection.writeLine("MAIL FROM:<\(address.mailbox)@\(address.host)>")
        let response = try await connection.readResponse()
        guard (200..<300).contains(response.code) else {
            throw CabalmailError.smtpCommandFailed(
                code: response.code,
                detail: response.lines.joined(separator: " ")
            )
        }
    }

    private func expect(_ connection: SmtpConnection, code: Int) async throws {
        let response = try await connection.readResponse()
        guard response.code == code else {
            throw CabalmailError.smtpCommandFailed(
                code: response.code,
                detail: response.lines.joined(separator: " ")
            )
        }
    }

    private func newMessageID(from: EmailAddress) -> String {
        "\(UUID().uuidString)@\(from.host)"
    }
}
