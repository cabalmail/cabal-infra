import SwiftUI

/// The title and SF Symbol of a reader control that toggles a state: the
/// read, flag, reader-view and remote-content toggles the mail and feed
/// readers share, and the mail reader's plain-text switch.
///
/// Every face names what a press does, in its glyph as well as its words:
/// a read message offers "Mark as unread" with the unread envelope, a
/// flagged one "Unflag" with the slashed flag, a message showing its
/// remote content "Hide remote content" with the slashed eye. A label that
/// flips with the state is a verb, and a verb takes the action's glyph —
/// as in Gmail's and Proton Mail's toolbars and Apple Mail's message
/// action sheet, and as this app's swipe actions, context menus and bulk
/// bar already drew them. The other common pattern, a fixed label whose
/// glyph fills while it is on (NetNewsWire's toolbar star), does not suit
/// a label that flips: the macOS » popup and the touch hold menus draw
/// the title beside the glyph, and "Mark as unread" beside an open
/// envelope contradicts itself.
///
/// Both readers and the macOS empty-pane stand-ins take their faces from
/// here. When each reader spelled its own, the mail reader's read toggle
/// drew the message's current state while the feed reader's drew the
/// action.
struct ReaderToggleFace: Equatable {
    let title: String
    let systemImage: String

    @MainActor
    var label: Label<Text, Image> {
        Label(title, systemImage: systemImage)
    }

    static func read(isRead: Bool) -> ReaderToggleFace {
        isRead
            ? ReaderToggleFace(title: "Mark as unread", systemImage: "envelope.badge")
            : ReaderToggleFace(title: "Mark as read", systemImage: "envelope.open")
    }

    static func flag(isFlagged: Bool) -> ReaderToggleFace {
        isFlagged
            ? ReaderToggleFace(title: "Unflag", systemImage: "flag.slash")
            : ReaderToggleFace(title: "Flag", systemImage: "flag")
    }

    /// The reader-view stylesheet draws a single left-aligned column of
    /// text; the original is the sender's (or publisher's) formatted page.
    static func readerView(isOn: Bool) -> ReaderToggleFace {
        isOn
            ? ReaderToggleFace(title: "Show original formatting", systemImage: "doc.richtext")
            : ReaderToggleFace(title: "Show reader view", systemImage: "text.alignleft")
    }

    static func remoteContent(isShown: Bool) -> ReaderToggleFace {
        isShown
            ? ReaderToggleFace(title: "Hide remote content", systemImage: "eye.slash")
            : ReaderToggleFace(title: "Show remote content", systemImage: "eye")
    }

    static func plainText(isOn: Bool) -> ReaderToggleFace {
        isOn
            ? ReaderToggleFace(title: "Show HTML", systemImage: "doc.richtext")
            : ReaderToggleFace(title: "Show plain text", systemImage: "doc.plaintext")
    }
}
