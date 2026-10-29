import XCTest
import CoreTransferable
import UniformTypeIdentifiers
import CabalmailKit
@testable import CabalmailUI

/// The message drag's two faces: the private move type the sidebar folders
/// decode, and the `.eml` a single message offers to other apps (#1650).
final class MessageDragPayloadTests: XCTestCase {

    private static let item = MessageDragItem(uid: 42, sourceFolder: "INBOX")
    private static let fetch: @Sendable () async throws -> Data = { Data("From: a@b\r\n".utf8) }

    func testWireFormCarriesItemsAndSubjectOnly() throws {
        let payload = MessageDragPayload(items: [Self.item], subject: "Hello", rawSource: Self.fetch)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(MessageDragPayload.self, from: data)
        XCTAssertEqual(decoded.items, [Self.item])
        XCTAssertEqual(decoded.subject, "Hello")
        // The fetch never crosses the wire: a decoded payload offers no .eml.
        XCTAssertNil(decoded.rawSource)
        XCTAssertFalse(decoded.exportsEml)
    }

    func testWireFormStaysReadableWithoutASubject() throws {
        // The pre-#1650 wire form had only `items`; a payload without a
        // subject must still round-trip, and the key must be absent rather
        // than null so an older decoder ignores it.
        let data = try JSONEncoder().encode(MessageDragPayload(items: [Self.item]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("subject"))
        XCTAssertEqual(try JSONDecoder().decode(MessageDragPayload.self, from: data).items, [Self.item])
    }

    func testOnlyASingleMessageWithAFetcherExportsEml() {
        XCTAssertTrue(MessageDragPayload(items: [Self.item], subject: nil, rawSource: Self.fetch).exportsEml)
        XCTAssertFalse(MessageDragPayload(items: [Self.item]).exportsEml, "no fetcher, nothing to export")
        let two = [Self.item, MessageDragItem(uid: 43, sourceFolder: "INBOX")]
        XCTAssertFalse(
            MessageDragPayload(items: two, subject: nil, rawSource: Self.fetch).exportsEml,
            "a multi-select drag is a move; one .eml cannot carry two messages"
        )
    }

    func testTheEmlIsAFileOfADataType() {
        // A receiver that takes any file looks for data; the abstract
        // `.emailMessage` is not, and the compose editor's page passed it over.
        XCTAssertTrue(UTType.emlFile.conforms(to: .data))
        XCTAssertEqual(UTType.emlFile.preferredFilenameExtension, "eml")
    }

    func testASingleMessageOffersItsEmlAheadOfTheMoveReference() {
        let provider = NSItemProvider()
        provider.register(MessageDragPayload(items: [Self.item], subject: "Hello", rawSource: Self.fetch))

        XCTAssertEqual(
            provider.registeredTypeIdentifiers,
            [UTType.emlFile.identifier, UTType.cabalmailMessageMove.identifier],
            "a receiver that takes the first data type it finds takes the .eml"
        )
    }

    func testSeveralMessagesOfferOnlyTheMoveReference() {
        let provider = NSItemProvider()
        let two = [Self.item, MessageDragItem(uid: 43, sourceFolder: "INBOX")]
        provider.register(MessageDragPayload(items: two, subject: nil, rawSource: Self.fetch))

        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.cabalmailMessageMove.identifier])
    }

    func testAFolderStillReadsTheMoveReferenceBehindTheEml() async throws {
        let provider = NSItemProvider()
        provider.register(MessageDragPayload(items: [Self.item], subject: "Hello", rawSource: Self.fetch))

        let read: MessageDragPayload = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: MessageDragPayload.self) { continuation.resume(with: $0) }
        }

        XCTAssertEqual(read.items, [Self.item])
    }

    func testEmlFilenameNeutralisesSeparatorsAndEmptySubjects() {
        XCTAssertEqual(emlFilename(for: "Re: plan"), "Re: plan.eml")
        XCTAssertEqual(emlFilename(for: "a/b"), "a_b.eml")
        XCTAssertEqual(emlFilename(for: "   "), "message.eml")
        XCTAssertEqual(emlFilename(for: nil), "message.eml")
    }
}
