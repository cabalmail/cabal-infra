import SwiftUI
import UniformTypeIdentifiers
import CabalmailKit

// Drag-and-drop plumbing for moving messages onto sidebar folders on the
// wide-screen layouts (iPad regular width, macOS, visionOS). The message
// rows in `MessageListView` are the drag source; the folder rows in
// `FolderListView` are the drop target. The payload is encoded as JSON
// under an app-private UTType and carried by an `NSItemProvider`, so a
// drag can never leak out of the app into Mail / Finder.
//
// The value types the payload decodes into (`MessageDragItem`) and the
// AppState signal a drop posts (`MessageMoveRequest`) live in
// `AppStateSignals.swift` because `AppState` references them and that file
// is Foundation-only; everything that needs SwiftUI / UniformTypeIdentifiers
// lives here.

extension UTType {
    /// App-internal drag type for moving messages onto sidebar folders.
    /// Declared as an exported type in both app targets' Info.plist
    /// (`UTExportedTypeDeclarations`, via `project.yml`) so Launch Services
    /// recognizes it and the runtime doesn't warn about an undeclared
    /// identifier. `.ownProcess` visibility on the item provider keeps the
    /// payload from ever leaving the app, so this never needs a filename
    /// tag or cross-app conformance beyond `public.data`.
    static let cabalmailMessageMove = UTType(exportedAs: "com.cabalmail.message-move")
}

/// The wire form of a message drag: the set of messages being moved, each
/// tagged with its owning mailbox so a cross-folder search selection routes
/// every UID back to the right source folder on drop.
struct MessageDragPayload: Codable {
    let items: [MessageDragItem]

    /// JSON-encode + register under the app-private UTType. `.ownProcess`
    /// confines the drag to this app. Returning the data through the load
    /// handler (rather than `registerObject`) keeps the representation a
    /// plain `Data` blob the drop side decodes with `JSONDecoder`.
    func makeItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.cabalmailMessageMove.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// Decode a payload from a provider's data representation. Returns nil
    /// if the blob is missing or malformed so the drop handler can treat it
    /// as a no-op rather than crash.
    static func decode(_ data: Data?) -> MessageDragPayload? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(MessageDragPayload.self, from: data)
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
