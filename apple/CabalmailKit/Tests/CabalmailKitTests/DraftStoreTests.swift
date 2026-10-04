import XCTest
@testable import CabalmailKit

final class DraftStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testSaveRoundTrip() async throws {
        let store = try DraftStore(directory: directory)
        let draft = Draft(
            fromAddress: "alice@mail.example.com",
            to: ["bob@example.com"],
            subject: "Hi",
            body: "there"
        )
        try await store.save(draft)
        let loaded = try await store.load(id: draft.id)
        XCTAssertEqual(loaded?.id, draft.id)
        XCTAssertEqual(loaded?.subject, "Hi")
        XCTAssertEqual(loaded?.body, "there")
        XCTAssertEqual(loaded?.to, ["bob@example.com"])
    }

    func testEmptyDraftIsNotPersisted() async throws {
        let store = try DraftStore(directory: directory)
        let empty = Draft()
        try await store.save(empty)
        let loaded = try await store.load(id: empty.id)
        XCTAssertNil(loaded)
    }

    func testEmptyDraftWithExistingOnDiskIsRemoved() async throws {
        // A draft starts populated; the user clears every field before
        // closing the window. Autosave should clean up the file rather
        // than leaving a stale empty one.
        let store = try DraftStore(directory: directory)
        var draft = Draft(subject: "Ongoing")
        try await store.save(draft)
        let stillThere = try await store.load(id: draft.id)
        XCTAssertNotNil(stillThere)

        draft.subject = ""
        draft.body = ""
        try await store.save(draft)
        let loaded = try await store.load(id: draft.id)
        XCTAssertNil(loaded)
    }

    func testListSortsNewestFirst() async throws {
        let store = try DraftStore(directory: directory)
        let older = Draft(subject: "older")
        try await store.save(older)
        // Ensure updatedAt ordering is stable across fast test machines.
        try await Task.sleep(nanoseconds: 10_000_000)
        let newer = Draft(subject: "newer")
        try await store.save(newer)
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.subject), ["newer", "older"])
    }

    func testRemoveDropsDraft() async throws {
        let store = try DraftStore(directory: directory)
        let draft = Draft(subject: "to remove")
        try await store.save(draft)
        try await store.remove(id: draft.id)
        let loaded = try await store.load(id: draft.id)
        XCTAssertNil(loaded)
    }

    func testCorruptFileIsQuarantinedNotDeleted() async throws {
        let store = try DraftStore(directory: directory)
        // Write a deliberately malformed JSON file to the drafts directory.
        let corruptName = UUID().uuidString
        let corruptURL = directory.appendingPathComponent("\(corruptName).json")
        try Data("not json".utf8).write(to: corruptURL)
        let good = Draft(subject: "good")
        try await store.save(good)

        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id), [good.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        let quarantined = try quarantinedFiles()
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(quarantined[0].lastPathComponent.hasPrefix(corruptName))
        XCTAssertEqual(try Data(contentsOf: quarantined[0]), Data("not json".utf8))
    }

    func testLoadQuarantinesAnUnreadableDraft() async throws {
        let store = try DraftStore(directory: directory)
        let id = UUID()
        try Data("{\"id\": 42}".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))

        let loaded = try await store.load(id: id)
        XCTAssertNil(loaded)
        XCTAssertEqual(try quarantinedFiles().count, 1)
    }

    func testSavedDraftCarriesASchemaVersion() async throws {
        let store = try DraftStore(directory: directory)
        let draft = Draft(subject: "versioned")
        try await store.save(draft)
        let data = try Data(contentsOf: directory.appendingPathComponent("\(draft.id.uuidString).json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, DraftStore.schemaVersion)
        XCTAssertNotNil(object["payload"])
    }

    func testLegacyUnversionedDraftStillLoads() async throws {
        // Files written before the schema envelope hold the bare `Draft`.
        let store = try DraftStore(directory: directory)
        let draft = Draft(to: ["bob@example.com"], subject: "from before")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(draft).write(to: directory.appendingPathComponent("\(draft.id.uuidString).json"))

        let loaded = try await store.load(id: draft.id)
        XCTAssertEqual(loaded?.subject, "from before")
        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id), [draft.id])
    }

    func testDraftFromANewerSchemaIsLeftInPlace() async throws {
        // A downgrade must not treat a newer build's draft as corrupt.
        let store = try DraftStore(directory: directory)
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        let newer = Data("{\"schemaVersion\": \(DraftStore.schemaVersion + 1), \"payload\": {}}".utf8)
        try newer.write(to: url)

        let listed = try await store.list()
        XCTAssertTrue(listed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try quarantinedFiles().isEmpty)
    }

    func testRemoveAllAlsoClearsQuarantine() async throws {
        let store = try DraftStore(directory: directory)
        try await store.save(Draft(subject: "keep me until sign-out"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        _ = try await store.list()
        XCTAssertEqual(try quarantinedFiles().count, 1)

        try await store.removeAll()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty, "left behind: \(remaining)")
    }

    private func quarantinedFiles() throws -> [URL] {
        let quarantine = directory.appendingPathComponent("quarantine")
        guard FileManager.default.fileExists(atPath: quarantine.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
    }

    func testLoadMissingReturnsNil() async throws {
        let store = try DraftStore(directory: directory)
        let loaded = try await store.load(id: UUID())
        XCTAssertNil(loaded)
    }

    func testSaveReplacesExisting() async throws {
        let store = try DraftStore(directory: directory)
        var draft = Draft(subject: "v1")
        try await store.save(draft)
        draft.subject = "v2"
        try await store.save(draft)
        let loaded = try await store.load(id: draft.id)
        XCTAssertEqual(loaded?.subject, "v2")
    }
}
