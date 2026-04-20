import XCTest
@testable import CabalmailKit

final class SmtpClientTests: XCTestCase {
    func testSubmissionHappyPath() async throws {
        let stream = ScriptedByteStream()
        let client = LiveSmtpClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService(),
            clientHostname: "cabalmail.local"
        )

        await stream.enqueue("220 smtp.example.com ESMTP ready\r\n")
        await stream.enqueue("250-smtp.example.com\r\n250 AUTH PLAIN LOGIN\r\n")
        await stream.enqueue("235 2.7.0 Authentication successful\r\n")
        await stream.enqueue("250 2.1.0 Sender ok\r\n")
        await stream.enqueue("250 2.1.5 Recipient ok\r\n")
        await stream.enqueue("354 Go ahead\r\n")
        await stream.enqueue("250 2.0.0 Queued\r\n")
        await stream.enqueue("221 Bye\r\n")

        let message = OutgoingMessage(
            from: EmailAddress(name: "Alice", mailbox: "alice", host: "example.com"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            subject: "Hello",
            textBody: "World"
        )

        try await client.send(message)

        let transcript = await stream.outboundString
        XCTAssertTrue(transcript.hasPrefix("EHLO cabalmail.local\r\n"))
        XCTAssertTrue(transcript.contains("MAIL FROM:<alice@example.com>"))
        XCTAssertTrue(transcript.contains("RCPT TO:<bob@example.com>"))
        XCTAssertTrue(transcript.contains("AUTH PLAIN "))
        XCTAssertTrue(transcript.contains("\r\n.\r\n"))
        XCTAssertTrue(transcript.contains("Subject: Hello"))
    }

    func testAuthFailureMapsToInvalidCredentials() async throws {
        let stream = ScriptedByteStream(autoEOFOnDrain: true)
        let client = LiveSmtpClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService(),
            clientHostname: "cabalmail.local"
        )
        await stream.enqueue("220 smtp\r\n")
        await stream.enqueue("250 smtp\r\n")
        await stream.enqueue("535 5.7.8 Authentication failed\r\n")

        do {
            try await client.send(
                OutgoingMessage(
                    from: EmailAddress(name: nil, mailbox: "a", host: "x"),
                    to: [EmailAddress(name: nil, mailbox: "b", host: "x")],
                    subject: "Hi",
                    textBody: "test"
                )
            )
            XCTFail("Expected invalid credentials")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }

    func testDotStuffingOnDataLeadingDots() async throws {
        let stream = ScriptedByteStream()
        let client = LiveSmtpClient(
            factory: ScriptedConnectionFactory(stream: stream),
            authService: StubAuthService()
        )
        await stream.enqueue("220 smtp\r\n")
        await stream.enqueue("250 smtp\r\n")
        await stream.enqueue("235 OK\r\n")
        await stream.enqueue("250 OK\r\n")
        await stream.enqueue("250 OK\r\n")
        await stream.enqueue("354 go\r\n")
        await stream.enqueue("250 queued\r\n")
        await stream.enqueue("221 bye\r\n")

        let body = ".leading dot\r\nsecond line\r\n"
        try await client.send(
            OutgoingMessage(
                from: EmailAddress(name: nil, mailbox: "a", host: "x"),
                to: [EmailAddress(name: nil, mailbox: "b", host: "x")],
                subject: "S",
                textBody: body
            )
        )
        let outbound = await stream.outboundString
        XCTAssertTrue(outbound.contains("\r\n..leading dot"))
    }
}
