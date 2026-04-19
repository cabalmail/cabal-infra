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

    func testCorruptFileIsSkippedAndRemoved() async throws {
        let store = try DraftStore(directory: directory)
        // Write a deliberately malformed JSON file to the drafts directory.
        let corruptURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: corruptURL)
        let good = Draft(subject: "good")
        try await store.save(good)

        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id), [good.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
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
