import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A UID names one row only inside one folder, so the identifier a row is
/// drawn under has to carry the folder wherever the list crosses folders --
/// the global search surface. In a folder list it stays the bare
/// `message.row.<uid>` the SimDrive recipes and source scans address
/// (#1991).
final class MessageRowIdentifierTests: XCTestCase {

    private static let inbox = Folder(path: "INBOX")

    private func envelope(uid: UInt32, folder: String?) -> Envelope {
        Envelope(uid: uid, subject: "probe \(uid)", folder: folder)
    }

    // MARK: - The two surfaces

    func testAFolderListRowKeepsTheBareIdentifier() {
        let row = envelope(uid: 316, folder: "INBOX")
        XCTAssertEqual(
            MessageRowIdentifier.identifier(for: row, scope: .folder(Self.inbox)),
            "message.row.316",
            "the recipes and scans address folder rows by UID alone"
        )
    }

    func testASearchRowCarriesItsFolder() {
        let row = envelope(uid: 316, folder: "Sent")
        XCTAssertEqual(
            MessageRowIdentifier.identifier(for: row, scope: .search),
            "message.row.Sent/316"
        )
    }

    /// The reported defect: two unrelated messages that happen to share a
    /// UID, both in one result set, were both `message.row.316`, so an `id:`
    /// query reached whichever the tree held first and nothing reached the
    /// other.
    func testTwoFoldersSharingAUIDGetDifferentSearchIdentifiers() {
        let sent = envelope(uid: 316, folder: "Sent")
        let inbox = envelope(uid: 316, folder: "INBOX")
        let identifiers = [sent, inbox].map {
            MessageRowIdentifier.identifier(for: $0, scope: .search)
        }
        XCTAssertEqual(identifiers, ["message.row.Sent/316", "message.row.INBOX/316"])
        XCTAssertEqual(Set(identifiers).count, 2, "each row has to be addressable on its own")
    }

    /// Negative control: the same two rows in a folder list still collide, so
    /// the test above is reading the scope and not the folder stamp.
    func testTheSameTwoRowsStillCollideInAFolderList() {
        let identifiers = [envelope(uid: 316, folder: "Sent"), envelope(uid: 316, folder: "INBOX")]
            .map { MessageRowIdentifier.identifier(for: $0, scope: .folder(Self.inbox)) }
        XCTAssertEqual(Set(identifiers), ["message.row.316"])
    }

    /// A nested folder's path is `/`-delimited already (`Folder.path`), so the
    /// UID is the last segment either way.
    func testANestedFolderKeepsItsWholePath() {
        let row = envelope(uid: 7, folder: "Archive/2026")
        XCTAssertEqual(
            MessageRowIdentifier.identifier(for: row, scope: .search),
            "message.row.Archive/2026/7"
        )
    }

    func testACrossFolderRowWithNoFolderFallsBackToTheBareForm() {
        XCTAssertEqual(
            MessageRowIdentifier.identifier(for: envelope(uid: 42, folder: nil), scope: .search),
            "message.row.42"
        )
        XCTAssertEqual(
            MessageRowIdentifier.identifier(uid: 42, folder: "", crossFolder: true),
            "message.row.42",
            "an empty path would read as message.row./42"
        )
    }

    func testEverySurfaceKeepsThePrefixTheRecipesMatchOn() {
        XCTAssertEqual(MessageRowIdentifier.prefix, "message.row")
        for identifier in [
            MessageRowIdentifier.identifier(uid: 1, folder: "INBOX", crossFolder: false),
            MessageRowIdentifier.identifier(uid: 1, folder: "INBOX", crossFolder: true)
        ] {
            XCTAssertTrue(identifier.hasPrefix("message.row."), identifier)
        }
    }

    // MARK: - The one call site

    /// The rule is inert unless the row asks it, and nothing renders the list
    /// in a unit test, so the pairing is pinned here: the row builder asks
    /// `MessageRowIdentifier` and hands it the list's own scope, and the file
    /// holds no hand-built identifier that would bypass it.
    func testTheRowBuilderAsksThePolicyWithTheListsScope() throws {
        let source = try Self.source(Self.listSource)
        let body = try Self.declaration("private func messageRow(", in: source)
        XCTAssertTrue(
            body.contains("MessageRowIdentifier.identifier(for: envelope, scope: scope)"),
            "the row's identifier comes from the policy, with the list's scope"
        )
        XCTAssertFalse(
            source.contains("\"message.row."),
            "a literal identifier anywhere in the list bypasses the policy"
        )
    }

    /// Detector self-test: the slice is one declaration, and the anchor is
    /// present. A rename must fail this scan rather than silently pass it.
    func testTheSliceIsOneDeclaration() throws {
        let source = try Self.source(Self.listSource)
        let body = try Self.declaration("private func messageRow(", in: source)
        XCTAssertTrue(body.contains("private func messageRow("))
        XCTAssertFalse(body.contains("private func activeMessageRow("))
        XCTAssertLessThan(body.count, source.count / 2)

        let synthetic = """
            extension A {
                private func messageRow(_ e: E) -> some View {
                    row.accessibilityIdentifier(MessageRowIdentifier.identifier(for: e, scope: scope))
                }

                private func activeMessageRow(_ e: E) -> some View {
                    nothing()
                }
            }
            """
        let slice = try Self.declaration("private func messageRow(", in: synthetic)
        XCTAssertTrue(slice.contains("MessageRowIdentifier.identifier("))
        XCTAssertFalse(slice.contains("nothing()"))
    }

    private static let listSource = "CabalmailUI/Mail/MessageList/MessageListView+Selection.swift"

    /// `source` from the opening line of `declaration` to the line that is
    /// its own indent plus `}`. A missing anchor FAILS rather than skips.
    private struct AnchorGone: Error, CustomStringConvertible {
        let description: String
    }

    private static func declaration(_ opener: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(opener) }) else {
            throw AnchorGone(description: "no declaration matching \(opener)")
        }
        let indent = String(lines[start].prefix(while: { $0 == " " }))
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == indent + "}" }) else {
            throw AnchorGone(description: "unterminated declaration \(opener)")
        }
        return lines[start...end].joined(separator: "\n")
    }

    private static func source(_ relativePath: String) throws -> String {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
