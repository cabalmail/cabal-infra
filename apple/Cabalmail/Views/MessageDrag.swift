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
// selection, which keeps single-click-to-open working. The cost is that the
// Transferable API offers no `.ownProcess` visibility knob, so the item is
// technically draggable out of the app - but it advertises only the custom
// `com.cabalmail.message-move` type (a tiny {uid, sourceFolder} JSON blob),
// which no other app claims, so in practice it goes nowhere else.
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
struct MessageDragPayload: Codable, Transferable {
    let items: [MessageDragItem]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cabalmailMessageMove)
    }
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
