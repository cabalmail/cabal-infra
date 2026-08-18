import Foundation
import CabalmailKit

/// Which pane the outgoing MIME parts are built from.
///
/// A message carries a `text/plain` and a `text/html` part, and the composer
/// has two surfaces that can fill them. This says which surface the user
/// actually authored; `ComposeViewModel.computeMessageBodies()` does the
/// WebKit conversions the answer implies.
enum ComposeBodySource: Equatable {
    /// Nothing worth sending in either pane.
    case empty
    /// The rich pane holds the authored copy: ship its HTML and derive the
    /// text part from it (turndown).
    case rich
    /// The Markdown pane holds the authored copy: ship it as the text part
    /// and render the HTML from it (marked + styleParagraphs).
    case markdown
    /// Both panes were authored independently — ship each as written.
    case both
}

/// Pure decision behind "which pane wins at send time". Split out of the
/// view model because the WebKit bridge sits in the middle of the code that
/// consumes it, and because the rule that was wrong here (#1091) is a rule
/// about *provenance*, not about conversion.
enum ComposeBodyPolicy {
    /// A non-empty Markdown buffer is not the same as a Markdown buffer the
    /// user wrote. `ComposeViewModel` seeds it before the user can type — a
    /// resumed draft seeds from the fetched `text/plain` part, a reply from
    /// the quoted original, and the signature preference from every compose
    /// — so "both panes are filled" was reading as "both panes were
    /// authored". A rich-pane edit over an untouched seed then shipped the
    /// seed verbatim as the text part while the HTML part carried the edit:
    /// one message, two different bodies, and (because resume prefers the
    /// text part) an edit that read as lost on the next Edit Draft (#1091).
    ///
    /// So the Markdown pane only counts as a second author once its
    /// contents differ from what was seeded into it.
    static func source(
        richHTML: String,
        richMirrorsMarkdown: Bool,
        markdownBody: String,
        markdownUserEdited: Bool
    ) -> ComposeBodySource {
        // A rich pane that has only ever been seeded from the Markdown
        // source is an echo, not a second copy — sending it would double up
        // the text part of a pure-Markdown compose.
        let richAuthored = !richHTML.isEmpty && !richMirrorsMarkdown
        let markdownFilled = !markdownBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch (richAuthored, markdownFilled) {
        case (false, false):
            return .empty
        case (true, false):
            return .rich
        case (false, true):
            return .markdown
        case (true, true):
            return markdownUserEdited ? .both : .rich
        }
    }

    /// Whether the body panes hold nothing but the signature the composer
    /// inserted itself.
    ///
    /// `hasDraftContent` used to ask whether the bodies were *empty*, and a
    /// signature-seeded compose is not: `SignatureFormatter.seedBody` fills
    /// the Markdown pane from `init`, before the user can type. So every
    /// new message a user with a signature abandoned raised the "Discard
    /// draft?" dialog that #1099 set out to remove, and every one they left
    /// open long enough autosaved a server draft containing their own
    /// signature and nothing else (#1132).
    ///
    /// Comparing against the seed rather than trusting a flag keeps this
    /// honest through `importFromRichText`, which re-seeds the Markdown
    /// pane with the user's own copy and resets the mirror: that body is
    /// not the signature seed, so it still counts.
    ///
    /// Deliberately narrow. A reply's quoted original and a resumed draft's
    /// fetched body are seeds too, and both stay content — discarding
    /// either is the data loss this check exists to avoid.
    static func bodyIsUntouchedSignature(
        markdownBody: String,
        richMirrorsMarkdown: Bool,
        signatureOnlySeed: String
    ) -> Bool {
        guard !signatureOnlySeed.isEmpty, richMirrorsMarkdown else { return false }
        return markdownBody == signatureOnlySeed
    }
}
