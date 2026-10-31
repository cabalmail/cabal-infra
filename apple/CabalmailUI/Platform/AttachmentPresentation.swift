import SwiftUI
import CabalmailKit
#if os(iOS) || os(visionOS)
import QuickLook
#elseif os(macOS)
import AppKit
#endif

/// Opens one of the open message's attachments: what an attachment control
/// in the reader calls (`\.openAttachment`), so every control that offers
/// an attachment opens it the same way.
struct OpenAttachmentAction {
    let open: @MainActor (MessageDetailViewModel.Attachment) -> Void

    @MainActor
    func callAsFunction(_ attachment: MessageDetailViewModel.Attachment) {
        open(attachment)
    }
}

extension EnvironmentValues {
    /// Published by `presentsAttachments()`; nil outside a reader that
    /// hosts it.
    @Entry var openAttachment: OpenAttachmentAction?
}

extension View {
    /// Hosts the reader's attachment presentation and publishes
    /// `\.openAttachment` to the views inside it. iOS and visionOS preview
    /// a file with Quick Look, and open an invitation in
    /// `CalendarEventSheet` with an Add to Calendar flow, since QuickLook
    /// can only display one and Calendar offers no share-sheet route (an
    /// invitation that doesn't parse still previews,
    /// `AttachmentOpenRoute`). macOS hands every file to the system, where
    /// an `.ics` lands in Calendar's own import prompt.
    func presentsAttachments() -> some View {
        modifier(AttachmentPresenter())
    }
}

private struct AttachmentPresenter: ViewModifier {
    @State private var previewURL: URL?
    #if canImport(EventKitUI)
    @State private var calendarInvite: CalendarInvite?
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.openAttachment, OpenAttachmentAction { open($0) })
            #if os(iOS) || os(visionOS)
            .quickLookPreview($previewURL)
            #endif
            #if canImport(EventKitUI)
            .sheet(item: $calendarInvite) { invite in
                CalendarEventSheet(invite: invite)
                    .windowShapedSheet()
            }
            #endif
    }

    @MainActor
    private func open(_ attachment: MessageDetailViewModel.Attachment) {
        #if os(macOS)
        NSWorkspace.shared.open(attachment.fileURL)
        #else
        #if canImport(EventKitUI)
        if let calendar = AttachmentOpenRoute.invitation(in: attachment) {
            calendarInvite = CalendarInvite(calendar: calendar)
            return
        }
        #endif
        previewURL = attachment.fileURL
        #endif
    }
}
