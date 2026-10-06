import XCTest
@testable import CabalmailKit

/// `MessageRef`, the folder-qualified message identity (workstream 1.1),
/// and the formats it converts to and from. The format pins here guard the
/// stored and wire shapes the conversion work promised not to change: the
/// envelope-cache snapshot, the Spotlight identifier, the resume record and
/// the reading-position keys.
final class MessageRefTests: XCTestCase {
    // MARK: - Identity

    func testIdentityIsFolderAndUID() {
        let inbox = MessageRef(folder: "INBOX", uid: 9)
        XCTAssertEqual(inbox, MessageRef(folder: "INBOX", uid: 9))
        XCTAssertNotEqual(inbox, MessageRef(folder: "Sent", uid: 9), "one UID in two folders is two messages")
        XCTAssertNotEqual(inbox, MessageRef(folder: "INBOX", uid: 10))
    }

    func testHintsTakeNoPartInEqualityOrHashing() {
        // A search row (no UIDVALIDITY) and a folder row (UIDVALIDITY known)
        // are the same message; so are refs with and without a Message-ID.
        let fromSearch = MessageRef(folder: "INBOX", uid: 9)
        let fromFolder = MessageRef(folder: "INBOX", uid: 9, uidValidity: 77, messageId: "<m@x>")
        XCTAssertEqual(fromSearch, fromFolder)
        XCTAssertEqual(Set([fromSearch, fromFolder]).count, 1)
        XCTAssertTrue(Set([fromFolder]).contains(fromSearch))
        XCTAssertEqual([fromFolder: 1][fromSearch], 1)
    }

    func testZeroUIDValidityMeansUnknown() {
        XCTAssertNil(MessageRef(folder: "INBOX", uid: 1, uidValidity: 0).uidValidity)
        XCTAssertNil(MessageRef(folder: "INBOX", uid: 1).withUIDValidity(0).uidValidity)
        XCTAssertEqual(MessageRef(folder: "INBOX", uid: 1).withUIDValidity(5).uidValidity, 5)
    }

    func testAConflictNeedsTwoKnownDifferentValues() {
        let known = MessageRef(folder: "INBOX", uid: 1, uidValidity: 5)
        XCTAssertTrue(known.conflicts(withUIDValidity: 6))
        XCTAssertFalse(known.conflicts(withUIDValidity: 5))
        XCTAssertFalse(known.conflicts(withUIDValidity: nil), "an unknown current value is no conflict")
        XCTAssertFalse(known.conflicts(withUIDValidity: 0), "0 is the app's 'unknown'")
        XCTAssertFalse(MessageRef(folder: "INBOX", uid: 1).conflicts(withUIDValidity: 6))
    }

    func testCodableRoundTripKeepsTheHints() throws {
        let ref = MessageRef(folder: "Archive/2024", uid: 42, uidValidity: 7, messageId: "<a@b>")
        let decoded = try JSONDecoder().decode(MessageRef.self, from: JSONEncoder().encode(ref))
        XCTAssertEqual(decoded, ref)
        XCTAssertEqual(decoded.uidValidity, 7)
        XCTAssertEqual(decoded.messageId, "<a@b>")
    }

    func testRefsGroupByFolderInFirstSeenOrder() {
        let refs = [
            MessageRef(folder: "INBOX", uid: 3),
            MessageRef(folder: "Archive", uid: 1),
            MessageRef(folder: "INBOX", uid: 1),
        ]
        XCTAssertEqual(refs.uidsByFolder(), ["INBOX": [3, 1], "Archive": [1]])
    }

    // MARK: - Envelope

    func testAnEnvelopeNamesItsMessageOnceItIsPlaced() {
        let envelope = TestFixtures.makeEnvelope(uid: 9, messageId: "<m@x>")
        XCTAssertNil(envelope.folder)
        XCTAssertNil(envelope.ref)
        let placed = envelope.inFolder("Sent")
        XCTAssertEqual(placed.ref, MessageRef(folder: "Sent", uid: 9))
        XCTAssertEqual(placed.ref?.messageId, "<m@x>")
        XCTAssertNotEqual(placed, envelope.inFolder("INBOX"), "the same message's row in two folders is two rows")
    }

    func testTheDefaultFolderAppliesOnlyToAnUnplacedEnvelope() {
        let unplaced = TestFixtures.makeEnvelope(uid: 4)
        let own = unplaced.ref(defaultFolder: "INBOX", uidValidity: 77)
        XCTAssertEqual(own, MessageRef(folder: "INBOX", uid: 4))
        XCTAssertEqual(own.uidValidity, 77)

        let elsewhere = unplaced.inFolder("Archive").ref(defaultFolder: "INBOX", uidValidity: 77)
        XCTAssertEqual(elsewhere, MessageRef(folder: "Archive", uid: 4))
        XCTAssertNil(elsewhere.uidValidity, "INBOX's UIDVALIDITY says nothing about Archive")
    }

    func testCopiesKeepTheFolder() {
        let placed = TestFixtures.makeEnvelope(uid: 2).inFolder("Receipts")
        XCTAssertEqual(placed.withFlags([.seen]).folder, "Receipts")
        XCTAssertEqual(
            placed.withThreading(messageId: "<t@x>", inReplyTo: nil, references: []).folder,
            "Receipts"
        )
    }

    /// The envelope-cache snapshot stores each envelope with exactly the
    /// keys it always had: the folder is never written, so snapshots on disk
    /// keep their bytes, and a snapshot decodes with no folder.
    func testTheEncodedEnvelopeCarriesNoFolder() throws {
        let envelope = Envelope(
            uid: 9,
            messageId: "<m@x>",
            date: Date(timeIntervalSince1970: 1),
            subject: "s",
            from: [EmailAddress(name: "A", mailbox: "a", host: "x.test")],
            sender: [EmailAddress(name: nil, mailbox: "a", host: "x.test")],
            replyTo: [EmailAddress(name: nil, mailbox: "r", host: "x.test")],
            to: [EmailAddress(name: nil, mailbox: "t", host: "x.test")],
            cc: [EmailAddress(name: nil, mailbox: "c", host: "x.test")],
            bcc: [EmailAddress(name: nil, mailbox: "b", host: "x.test")],
            inReplyTo: "<p@x>",
            references: ["<p@x>"],
            flags: [.seen],
            internalDate: Date(timeIntervalSince1970: 2),
            size: 10,
            hasAttachments: true,
            isImportant: true,
            authResults: nil,
            folder: "INBOX"
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "uid", "messageId", "date", "subject", "from", "sender", "replyTo", "to", "cc", "bcc",
            "inReplyTo", "references", "flags", "internalDate", "size", "hasAttachments", "isImportant",
        ])
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        XCTAssertNil(decoded.folder)
        XCTAssertEqual(decoded, envelope.withoutFolderForTest())
    }

    func testASearchRowIsPlacedInItsFolder() {
        let row = SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 1), folder: "zeta0802")
        XCTAssertEqual(row.envelope.folder, "zeta0802")
        XCTAssertEqual(row.ref, MessageRef(folder: "zeta0802", uid: 1))
        XCTAssertNil(row.ref.uidValidity, "the search wire carries no UIDVALIDITY")
    }

    // MARK: - Spotlight

    /// The identifier lives in the system index; a format change that still
    /// round-trips would orphan every donated item. "SU5CT1g" is INBOX in
    /// unpadded base64url.
    func testTheSpotlightIdentifierIsUnchanged() {
        let ref = MessageRef(folder: "INBOX", uid: 42, uidValidity: 7, messageId: "<m@x>")
        XCTAssertEqual(SpotlightMessageRef(ref).stringValue, "cabalmail-msg|v1|SU5CT1g|42")
        XCTAssertEqual(SpotlightMessageRef(string: "cabalmail-msg|v1|SU5CT1g|42")?.messageRef, ref)
    }

    // MARK: - Nav cursor and resume record

    func testAMailCursorNamesItsMessage() {
        let cursor = NavState(folder: "Archive", messageID: "<m@x>", uid: 12, uidValidity: 3, clientID: "c")
        XCTAssertEqual(cursor.messageRef, MessageRef(folder: "Archive", uid: 12))
        XCTAssertEqual(cursor.messageRef?.uidValidity, 3)
        XCTAssertEqual(cursor.messageRef?.messageId, "<m@x>")
        XCTAssertNil(NavState(folder: "Archive", messageID: "<m@x>", clientID: "c").messageRef)
        XCTAssertNil(NavState.feed(itemID: "f#1", scope: nil, clientID: "c").messageRef)
    }

    func testTheResumeRecordConvertsAndKeepsItsKeys() throws {
        var session = ResumeSession(section: .mail, folder: "INBOX", savedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(session.messageRef)
        session.setMessage(MessageRef(folder: "Sent", uid: 5, uidValidity: 9, messageId: "<s@x>"))
        XCTAssertEqual(session.folder, "Sent")
        XCTAssertEqual(session.uid, 5)
        XCTAssertEqual(session.messageID, "<s@x>")
        XCTAssertEqual(session.messageRef, MessageRef(folder: "Sent", uid: 5))

        // The record is stored as JSON in UserDefaults: its keys stay as
        // they were, with no UIDVALIDITY added.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["section", "folder", "uid", "messageID", "savedAt"])
        let legacy = Data(#"{"section":"mail","folder":"INBOX","uid":3,"messageID":"<l@x>","savedAt":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ResumeSession.self, from: legacy).messageRef,
                       MessageRef(folder: "INBOX", uid: 3))
    }

    func testTheReadingPositionKeyIsUnchanged() {
        let withID = MessageRef(folder: "F", uid: 1, uidValidity: 9, messageId: "<id>")
        XCTAssertEqual(ReadingPositionKey.mail(withID), "mail:<id>")
        XCTAssertEqual(ReadingPositionKey.mail(MessageRef(folder: "F", uid: 1, uidValidity: 9)), "mail:F#1")
    }

    // MARK: - Drafts

    func testADraftServerCopyIsAMessageInDrafts() {
        let server = DraftServerRef(uid: 625, uidValidity: 9)
        XCTAssertEqual(server.messageRef(), MessageRef(folder: FolderTree.draftsPath, uid: 625))
        XCTAssertEqual(server.messageRef().uidValidity, 9)
        XCTAssertEqual(DraftServerRef(server.messageRef()), server)
    }

    func testARefWithoutUIDValidityNamesNoServerCopy() {
        XCTAssertNil(DraftServerRef(MessageRef(folder: FolderTree.draftsPath, uid: 7)))
        XCTAssertNil(DraftServerRef(MessageRef(folder: FolderTree.draftsPath, uid: 7, uidValidity: 0)))
        XCTAssertEqual(DraftServerRef(uid: 7, uidValidity: 0).messageRef().uidValidity, nil)
    }

    func testADraftNamesTheMessageItReplies() {
        var draft = Draft()
        XCTAssertNil(draft.replySource)
        draft.replySourceFolder = "INBOX"
        draft.replySourceUid = 31
        XCTAssertEqual(draft.replySource, MessageRef(folder: "INBOX", uid: 31))
    }
}

private extension Envelope {
    /// The same envelope with no folder, for comparing against a decode.
    func withoutFolderForTest() -> Envelope {
        Envelope(
            uid: uid, messageId: messageId, date: date, subject: subject, from: from, sender: sender,
            replyTo: replyTo, to: to, cc: cc, bcc: bcc, inReplyTo: inReplyTo, references: references,
            flags: flags, internalDate: internalDate, size: size, hasAttachments: hasAttachments,
            isImportant: isImportant, authResults: authResults
        )
    }
}
