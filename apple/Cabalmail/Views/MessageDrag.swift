import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import CabalmailKit

// Drag-and-drop plumbing for moving messages onto sidebar folders on the
// wide-screen layouts (iPad regular width, macOS, visionOS). The message
// rows in `MessageListView` are the drag source (`.draggable`); the folder
// rows in `FolderListView` are the drop target (`.dropDestination`).
//
// `.draggable` / `.dropDestination` (rather than the lower-level
// `.onDrag` / `.onDrop`) is deliberate: `.onDrag` on a `List(selection:)`
// row swallows clicks on the row's rendered content on macOS, so a plain
// click on the subject / sender text no longer selects the row (only clicks
// on empty cell area do). `.draggable` is built to coexist with list-row
// selection, which keeps single-click-to-open working. The Transferable API
// offers no `.ownProcess` visibility knob, so the item is draggable out of
// the app. Its first (highest-fidelity) representation is the custom
// `com.cabalmail.message-move` type (a tiny {uid, sourceFolder} JSON blob)
// that only the sidebar folders claim; a single-message drag also offers the
// raw RFC 5322 source as an `.eml` document, so it can land in Files, Mail,
// or Notes in the other Split View pane — on an open iPhone Duo, an iPad, or
// the Mac (#1650). The bytes are fetched lazily, only when a receiver asks
// for that type, through the same body cache the reader fills.
//
// The value types the payload carries (`MessageDragItem`) and the AppState
// signal a drop posts (`MessageMoveRequest`) live in `AppStateSignals.swift`
// because `AppState` references them and that file is Foundation-only;
// everything that needs SwiftUI / CoreTransferable lives here.

extension UTType {
    /// App-private drag type for moving messages onto sidebar folders.
    /// Declared as an exported type in both app targets' Info.plist
    /// (`UTExportedTypeDeclarations`, via `project.yml`) so Launch Services
    /// recognizes it and the runtime doesn't warn about an undeclared
    /// identifier. Conforms only to `public.data`; no filename tag because
    /// it's never written to disk or shared.
    static let cabalmailMessageMove = UTType(exportedAs: "com.cabalmail.message-move")
}

/// The wire form of a message drag: the set of messages being moved, each
/// tagged with its owning mailbox so a cross-folder search selection routes
/// every UID back to the right source folder on drop. `Transferable` so it
/// rides `.draggable` on the source side and is decoded automatically by
/// `.dropDestination(for: MessageDragPayload.self)` on the folder side.
///
/// Only `items` and `subject` are on the wire; `rawSource` is the lazy
/// fetch behind the `.eml` representation and never leaves the process (a
/// decoded payload has none, and `exportsEml` is false for it).
struct MessageDragPayload: Codable, Transferable {
    let items: [MessageDragItem]
    /// The dragged message's subject, for the `.eml` file name. Nil for a
    /// multi-message drag, which offers no `.eml`.
    let subject: String?
    /// Fetches the raw RFC 5322 bytes of the single dragged message. Set by
    /// the drag source for a single-item drag; nil otherwise.
    let rawSource: (@Sendable () async throws -> Data)?

    init(items: [MessageDragItem], subject: String? = nil, rawSource: (@Sendable () async throws -> Data)? = nil) {
        self.items = items
        self.subject = subject
        self.rawSource = rawSource
    }

    private enum CodingKeys: String, CodingKey {
        case items, subject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([MessageDragItem].self, forKey: .items)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        rawSource = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(subject, forKey: .subject)
    }

    /// Whether this drag offers an `.eml`: exactly one message, with a
    /// fetcher attached. A multi-select drag is a move, not an export — one
    /// `.eml` cannot carry several messages, and a receiver that took the
    /// first would silently drop the rest.
    var exportsEml: Bool {
        items.count == 1 && rawSource != nil
    }

    static var transferRepresentation: some TransferRepresentation {
        // First = preferred: the sidebar's folder drop decodes this one, and
        // an external receiver that understands neither type gets nothing.
        CodableRepresentation(contentType: .cabalmailMessageMove)
        DataRepresentation(exportedContentType: .emailMessage) { payload in
            guard let rawSource = payload.rawSource else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try await rawSource()
        }
        .exportingCondition { $0.exportsEml }
        .suggestedFileName { emlFilename(for: $0.subject) }
    }
}

/// The raw RFC 5322 bytes of one message, through the reader's body cache:
/// a message that has been read is served from disk, anything else is
/// fetched and cached the way the reader would have. The same three steps as
/// `MessageDetailViewModel.fetchBodyBytes`, for a caller that has no
/// detail model — a drag that lifts from the list.
enum MessageRawSource {
    static func bytes(client: CabalmailClient, folder: String, uid: UInt32) async throws -> Data {
        let uidValidity: UInt32
        if let snapshot = await client.envelopeCache.snapshot(for: folder) {
            uidValidity = snapshot.uidValidity
        } else {
            uidValidity = try await client.imapClient.status(path: folder).uidValidity ?? 0
        }
        if let cached = await client.bodyCache.fetch(folder: folder, uidValidity: uidValidity, uid: uid) {
            return cached
        }
        try await client.imapClient.connectAndAuthenticate()
        let raw = try await client.imapClient.fetchBody(folder: folder, uid: uid)
        try await client.bodyCache.store(folder: folder, uidValidity: uidValidity, uid: uid, bytes: raw.bytes)
        return raw.bytes
    }
}

/// File name for a message exported as `.eml`: the subject with path
/// separators neutralised, or "message" when there is none. Shared by the
/// View Source sheet's Share and the list's drag-out.
func emlFilename(for subject: String?) -> String {
    let base = (subject ?? "message")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = base.isEmpty ? "message" : base
    return "\(safe).eml"
}

/// Drag image shown under the cursor / finger while a message drag is in
/// flight. Collapses to a count for multi-select so a 20-message drag
/// doesn't try to render 20 subjects.
struct MessageDragPreview: View {
    let count: Int
    let subject: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: count > 1 ? "envelope.fill" : "envelope")
                .foregroundStyle(.tint)
            Text(label)
                .lineLimit(1)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 260)
        .background(.regularMaterial, in: Capsule())
    }

    private var label: String {
        if count > 1 { return "\(count) messages" }
        let trimmed = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return "Message"
    }
}
