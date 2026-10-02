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

    func testCorruptFileIsQuarantinedNotDeleted() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "good"))
        let corruptName = UUID().uuidString
        let corruptURL = directory.appendingPathComponent("\(corruptName).json")
        try Data("not json".utf8).write(to: corruptURL)

        let list = try await outbox.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        let quarantined = try quarantinedFiles()
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(quarantined[0].lastPathComponent.hasPrefix(corruptName))
        XCTAssertEqual(try Data(contentsOf: quarantined[0]), Data("not json".utf8))
    }

    func testStoredEntryCarriesASchemaVersion() async throws {
        let outbox = try Outbox(directory: directory)
        let entry = try await outbox.enqueue(Self.makeMessage(subject: "versioned"))
        let data = try Data(contentsOf: directory.appendingPathComponent("\(entry.id.uuidString).json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, Outbox.schemaVersion)
        XCTAssertNotNil(object["payload"])
    }

    func testLegacyUnversionedEntryStillLoads() async throws {
        // Entries queued before the schema envelope (and before `failedAt`)
        // hold the bare `Entry`; an upgrade must still send them.
        let outbox = try Outbox(directory: directory)
        let id = UUID()
        let message = Self.makeMessage(subject: "queued by an older build")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(Outbox.Entry(id: id, attempts: 2, message: message)))
                as? [String: Any]
        )
        legacy["failedAt"] = nil
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appendingPathComponent("\(id.uuidString).json"))

        let list = try await outbox.list()
        XCTAssertEqual(list.map(\.id), [id])
        XCTAssertEqual(list.first?.attempts, 2)
        XCTAssertEqual(list.first?.isFailed, false)
    }

    func testEntryFromANewerSchemaIsLeftInPlace() async throws {
        let outbox = try Outbox(directory: directory)
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{\"schemaVersion\": \(Outbox.schemaVersion + 1), \"payload\": {}}".utf8).write(to: url)

        let list = try await outbox.list()
        XCTAssertTrue(list.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try quarantinedFiles().isEmpty)
    }

    func testResetForRetryClearsTheFailure() async throws {
        let outbox = try Outbox(directory: directory)
        var entry = try await outbox.enqueue(Self.makeMessage(subject: "try again"))
        entry.attempts = 10
        entry.lastAttemptAt = Date()
        entry.lastError = "timeout"
        entry.failedAt = Date()
        try await outbox.update(entry)
        let failedBefore = try await outbox.failed()
        XCTAssertEqual(failedBefore.map(\.id), [entry.id])

        try await outbox.resetForRetry(id: entry.id)
        let afterReset = try await outbox.list()
        let reset = try XCTUnwrap(afterReset.first)
        XCTAssertEqual(reset.attempts, 0)
        XCTAssertNil(reset.lastAttemptAt)
        XCTAssertNil(reset.lastError)
        XCTAssertFalse(reset.isFailed)
        let failedAfter = try await outbox.failed()
        XCTAssertTrue(failedAfter.isEmpty)
    }

    func testChangesStreamsTheCurrentListThenEachChange() async throws {
        let outbox = try Outbox(directory: directory)
        let stream = await outbox.changes()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        var entry = try await outbox.enqueue(Self.makeMessage(subject: "watched"))
        let afterEnqueue = await iterator.next()
        XCTAssertEqual(afterEnqueue?.map(\.id), [entry.id])

        entry.failedAt = Date()
        try await outbox.update(entry)
        let afterFailure = await iterator.next()
        XCTAssertEqual(afterFailure?.first?.isFailed, true)

        try await outbox.remove(id: entry.id)
        let afterRemove = await iterator.next()
        XCTAssertEqual(afterRemove?.count, 0)
    }

    func testRemoveAllAlsoClearsQuarantine() async throws {
        let outbox = try Outbox(directory: directory)
        _ = try await outbox.enqueue(Self.makeMessage(subject: "queued"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        _ = try await outbox.list()
        XCTAssertEqual(try quarantinedFiles().count, 1)

        try await outbox.removeAll()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty, "left behind: \(remaining)")
    }

    private func quarantinedFiles() throws -> [URL] {
        let quarantine = directory.appendingPathComponent("quarantine")
        guard FileManager.default.fileExists(atPath: quarantine.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
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
