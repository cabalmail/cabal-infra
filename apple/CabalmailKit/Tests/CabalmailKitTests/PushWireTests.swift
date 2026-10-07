import CabalmailShared
import XCTest

/// The two push wire formats the Notification Service Extension and the app
/// share through CabalmailShared: the payload's `msgRef` (also the
/// `/push_envelope` request body) and the `/push_envelope` reply. The
/// extension has no test target, so its rules are pinned here, on the type
/// it parses, writes and decodes with.
final class PushWireTests: XCTestCase {
    private func payload(_ ref: Any) -> [AnyHashable: Any] {
        ["aps": ["alert": "New mail", "mutable-content": 1], "msgRef": ref]
    }

    func testKeysKeepTheirWireNames() {
        XCTAssertEqual(PushMessageCoordinates.Key.msgRef, "msgRef")
        XCTAssertEqual(PushMessageCoordinates.Key.folder, "folder")
        XCTAssertEqual(PushMessageCoordinates.Key.uid, "uid")
        XCTAssertEqual(PushMessageCoordinates.Key.messageID, "msg_id")
    }

    func testAFullRefParses() throws {
        let parsed = try XCTUnwrap(PushMessageCoordinates(userInfo: payload(
            ["folder": "INBOX", "uid": 4271, "msg_id": "<m1@example.com>"]
        )))
        XCTAssertEqual(parsed, PushMessageCoordinates(folder: "INBOX", uid: 4271, messageID: "<m1@example.com>"))
    }

    /// 0 is the dispatch Lambda's "no hint" sentinel: the ref still parses,
    /// without a uid, so the actions skip rather than flag or move UID 0.
    func testAUidOfZeroParsesAsNoUid() throws {
        let parsed = try XCTUnwrap(PushMessageCoordinates(userInfo: payload(
            ["folder": "INBOX", "uid": 0, "msg_id": "<m1@example.com>"]
        )))
        XCTAssertNil(parsed.uid)
        XCTAssertEqual(parsed.messageID, "<m1@example.com>")
    }

    func testAMissingUidParsesAsNoUid() throws {
        let parsed = try XCTUnwrap(PushMessageCoordinates(userInfo: payload(
            ["folder": "INBOX", "msg_id": "<m1@example.com>"]
        )))
        XCTAssertNil(parsed.uid)
    }

    func testAnEmptyOrMissingMessageIDParsesAsNone() throws {
        let empty = try XCTUnwrap(PushMessageCoordinates(userInfo: payload(
            ["folder": "INBOX", "uid": 4271, "msg_id": ""]
        )))
        XCTAssertNil(empty.messageID)
        XCTAssertEqual(empty.uid, 4271)

        let missing = try XCTUnwrap(PushMessageCoordinates(userInfo: payload(["folder": "INBOX", "uid": 4271])))
        XCTAssertNil(missing.messageID)
    }

    func testARefWithoutAUsableFolderDoesNotParse() {
        XCTAssertNil(PushMessageCoordinates(userInfo: ["aps": ["alert": "New mail"]]))
        XCTAssertNil(PushMessageCoordinates(userInfo: payload("INBOX")))
        XCTAssertNil(PushMessageCoordinates(userInfo: payload(["uid": 4271])))
        XCTAssertNil(PushMessageCoordinates(userInfo: payload(["folder": "", "uid": 4271])))
        XCTAssertNil(PushMessageCoordinates(userInfo: payload(["folder": 7, "uid": 4271])))
    }

    func testTheRequestBodyOmitsWhatIsNotSet() throws {
        let bare = PushMessageCoordinates(folder: "INBOX", uid: nil, messageID: nil).requestBody
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare["folder"] as? String, "INBOX")

        let full = PushMessageCoordinates(folder: "INBOX", uid: 4271, messageID: "<m1@example.com>").requestBody
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(full["uid"] as? Int, 4271)
        XCTAssertEqual(full["msg_id"] as? String, "<m1@example.com>")

        // The bytes the server reads: no null anywhere.
        let json = try JSONSerialization.data(withJSONObject: bare)
        XCTAssertEqual(String(data: json, encoding: .utf8), #"{"folder":"INBOX"}"#)
    }

    /// The memberwise init keeps what it is given, so `fetchPushEnvelope`
    /// sends exactly the arguments it was called with; reading the 0 and ""
    /// sentinels is the payload parse's job.
    func testTheMemberwiseInitKeepsItsValues() {
        let body = PushMessageCoordinates(folder: "INBOX", uid: 0, messageID: "").requestBody
        XCTAssertEqual(body["uid"] as? Int, 0)
        XCTAssertEqual(body["msg_id"] as? String, "")
    }

    func testAPostedNotificationsUserInfoParsesBack() {
        let coordinates = PushMessageCoordinates(folder: "Archive", uid: 12, messageID: "<m2@example.com>")
        XCTAssertEqual(PushMessageCoordinates(userInfo: coordinates.userInfo), coordinates)
        XCTAssertEqual(coordinates.userInfo.count, 1)
    }

    func testResolvingTakesAResolvedUidAndOtherwiseKeepsTheHint() {
        let hinted = PushMessageCoordinates(folder: "INBOX", uid: 4271, messageID: "<m1@example.com>")
        XCTAssertEqual(hinted.resolving(4272).uid, 4272)
        XCTAssertEqual(hinted.resolving(0).uid, 4271)
        XCTAssertEqual(hinted.resolving(nil).uid, 4271)
        XCTAssertEqual(hinted.resolving(4272).messageID, "<m1@example.com>")

        let unhinted = PushMessageCoordinates(folder: "INBOX", uid: nil, messageID: "<m1@example.com>")
        XCTAssertNil(unhinted.resolving(0).uid)
    }

    /// The extension's rule: replace the uid and leave everything else in the
    /// delivered payload as it was, the alert, a sentinel `msg_id` and any key
    /// a later dispatch adds included.
    func testPatchingReplacesOnlyTheUid() throws {
        let delivered = payload(["folder": "INBOX", "uid": 0, "msg_id": "", "uidvalidity": 9])
        let patched = try XCTUnwrap(PushMessageCoordinates.patching(delivered, resolvedUID: 4272))

        let ref = try XCTUnwrap(patched["msgRef"] as? [String: Any])
        XCTAssertEqual(ref["uid"] as? Int, 4272)
        XCTAssertEqual(ref["msg_id"] as? String, "")
        XCTAssertEqual(ref["uidvalidity"] as? Int, 9)
        XCTAssertEqual(ref["folder"] as? String, "INBOX")
        XCTAssertEqual(ref.count, 4)
        XCTAssertNotNil(patched["aps"])
        XCTAssertEqual(patched.count, 2)
    }

    func testPatchingLeavesTheNotificationAloneWithoutAResolvedUid() {
        let delivered = payload(["folder": "INBOX", "uid": 4271])
        XCTAssertNil(PushMessageCoordinates.patching(delivered, resolvedUID: nil))
        XCTAssertNil(PushMessageCoordinates.patching(delivered, resolvedUID: 0))
        XCTAssertNil(PushMessageCoordinates.patching(["aps": [:]], resolvedUID: 4272))
        XCTAssertNil(PushMessageCoordinates.patching(payload("INBOX"), resolvedUID: 4272))
    }

    func testTheEnvelopeReplyDecodesWithOrWithoutAUid() throws {
        let resolved = try JSONDecoder().decode(PushEnvelope.self, from: Data(
            #"{"from":"Alice","subject":"Hi","snippet":"Lunch?","uid":4272}"#.utf8
        ))
        XCTAssertEqual(resolved, PushEnvelope(from: "Alice", subject: "Hi", snippet: "Lunch?", uid: 4272))

        let missing = try JSONDecoder().decode(PushEnvelope.self, from: Data(
            #"{"from":"Alice","subject":"Hi","snippet":"Lunch?"}"#.utf8
        ))
        XCTAssertNil(missing.uid)
        let null = try JSONDecoder().decode(PushEnvelope.self, from: Data(
            #"{"from":"Alice","subject":"Hi","snippet":"Lunch?","uid":null}"#.utf8
        ))
        XCTAssertNil(null.uid)
    }

    func testTheEnvelopeReplyWithoutASenderDoesNotDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(PushEnvelope.self, from: Data(
            #"{"subject":"Hi","snippet":"Lunch?","uid":4272}"#.utf8
        )))
    }
}
