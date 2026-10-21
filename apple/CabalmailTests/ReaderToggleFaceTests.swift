import XCTest
@testable import CabalmailUI

/// The reader toggles' faces: each glyph names the action its label names,
/// and the mail and feed readers draw the same face for the same toggle.
/// The mail reader's read toggle once drew the message's current state (an
/// open envelope beside "Mark as unread") while the feed reader's drew the
/// action, and the remote-content and reader-view toggles drew state beside
/// action labels in both.
final class ReaderToggleFaceTests: XCTestCase {
    private func assertFace(
        _ face: ReaderToggleFace,
        _ title: String,
        _ systemImage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(face, ReaderToggleFace(title: title, systemImage: systemImage), file: file, line: line)
    }

    func testEachFaceDrawsTheActionItsLabelNames() {
        assertFace(.read(isRead: true), "Mark as unread", "envelope.badge")
        assertFace(.read(isRead: false), "Mark as read", "envelope.open")
        assertFace(.flag(isFlagged: true), "Unflag", "flag.slash")
        assertFace(.flag(isFlagged: false), "Flag", "flag")
        assertFace(.readerView(isOn: true), "Show original formatting", "doc.richtext")
        assertFace(.readerView(isOn: false), "Show reader view", "text.alignleft")
        assertFace(.remoteContent(isShown: true), "Hide remote content", "eye.slash")
        assertFace(.remoteContent(isShown: false), "Show remote content", "eye")
        assertFace(.plainText(isOn: true), "Show HTML", "doc.richtext")
        assertFace(.plainText(isOn: false), "Show plain text", "doc.plaintext")
    }

    /// The slash variant marks the press that takes something away, so it
    /// belongs on the face of the state that has the thing — the flagged
    /// message, the message showing its remote content — never on the face
    /// that offers to add it.
    func testTheSlashSitsOnTheFaceThatRemoves() {
        XCTAssertTrue(ReaderToggleFace.flag(isFlagged: true).systemImage.hasSuffix(".slash"))
        XCTAssertFalse(ReaderToggleFace.flag(isFlagged: false).systemImage.hasSuffix(".slash"))
        XCTAssertTrue(ReaderToggleFace.remoteContent(isShown: true).systemImage.hasSuffix(".slash"))
        XCTAssertFalse(ReaderToggleFace.remoteContent(isShown: false).systemImage.hasSuffix(".slash"))
    }

    /// A toggle whose two faces matched would hide its state.
    func testEveryToggleChangesItsGlyph() {
        let pairs: [(ReaderToggleFace, ReaderToggleFace)] = [
            (.read(isRead: true), .read(isRead: false)),
            (.flag(isFlagged: true), .flag(isFlagged: false)),
            (.readerView(isOn: true), .readerView(isOn: false)),
            (.remoteContent(isShown: true), .remoteContent(isShown: false)),
            (.plainText(isOn: true), .plainText(isOn: false))
        ]
        for (onFace, offFace) in pairs {
            XCTAssertNotEqual(onFace.systemImage, offFace.systemImage, onFace.title)
        }
    }

    /// One toggle both readers draw: its mail and feed actions and the face
    /// it shows in the quiescent state.
    private struct SharedToggle {
        let mail: ReaderToolbarAction
        let feed: FeedReaderAction
        let face: ReaderToggleFace
    }

    /// The macOS empty-pane stand-ins draw the quiescent face, and the two
    /// readers' stand-ins agree with each other for every toggle they share.
    func testStandInsDrawTheQuiescentFaceInBothReaders() {
        let shared = [
            SharedToggle(mail: .toggleRead, feed: .read, face: .read(isRead: false)),
            SharedToggle(mail: .toggleFlag, feed: .favorite, face: .flag(isFlagged: false)),
            SharedToggle(mail: .readerMode, feed: .readerMode, face: .readerView(isOn: false)),
            SharedToggle(mail: .remoteContent, feed: .remoteContent, face: .remoteContent(isShown: false))
        ]
        for toggle in shared {
            XCTAssertEqual(toggle.mail.quiescentSymbol, toggle.face.systemImage, toggle.mail.rawValue)
            XCTAssertEqual(toggle.mail.quiescentTitle, toggle.face.title, toggle.mail.rawValue)
            XCTAssertEqual(toggle.feed.quiescentSymbol, toggle.face.systemImage, toggle.feed.rawValue)
            XCTAssertEqual(toggle.feed.quiescentTitle, toggle.face.title, toggle.feed.rawValue)
        }
        let plainText = ReaderToggleFace.plainText(isOn: false)
        XCTAssertEqual(ReaderToolbarAction.plainText.quiescentSymbol, plainText.systemImage)
        XCTAssertEqual(ReaderToolbarAction.plainText.quiescentTitle, plainText.title)
    }
}
