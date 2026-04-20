import XCTest
@testable import CabalmailKit

final class OutboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testEnqueueRoundTrip() async throws {
        let outbox = try Outbox(directory: directory)
        let message = Self.makeMessage(subject: "hi")
        let entry = try await outbox.enqueue(message)
        let list = try await outbox.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, entry.id)
        XCTAssertEqual(list.first?.message.subject, "hi")
    }

    func testListSortsOldestFirst() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "first"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "second"))
        let list = try await outbox.list()
        XCTAssertEqual(list.map(\.message.subject), ["first", "second"])
    }

    func testRemoveDropsEntry() async throws {
        let outbox = try Outbox(directory: directory)
        let entry = try await outbox.enqueue(Self.makeMessage(subject: "bye"))
        try await outbox.remove(id: entry.id)
        let list = try await outbox.list()
        XCTAssertTrue(list.isEmpty)
    }

    func testUpdatePersistsRetryState() async throws {
        let outbox = try Outbox(directory: directory)
        var entry = try await outbox.enqueue(Self.makeMessage(subject: "retry"))
        entry.attempts = 3
        entry.lastError = "timeout"
        try await outbox.update(entry)
        let list = try await outbox.list()
        XCTAssertEqual(list.first?.attempts, 3)
        XCTAssertEqual(list.first?.lastError, "timeout")
    }

    func testCorruptFileIsSkippedAndRemoved() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "good"))
        let corruptURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: corruptURL)

        let list = try await outbox.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    private static func makeMessage(subject: String) -> OutgoingMessage {
        OutgoingMessage(
            from: EmailAddress(name: nil, mailbox: "alice", host: "example.com"),
            to: [EmailAddress(name: nil, mailbox: "bob", host: "example.com")],
            cc: [],
            bcc: [],
            subject: subject,
            textBody: "body",
            htmlBody: nil,
            inReplyTo: nil,
            references: [],
            attachments: [],
            extraHeaders: [:],
            messageId: nil
        )
    }
}
