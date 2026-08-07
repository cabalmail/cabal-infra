#if os(iOS)
import AppIntents
import CabalmailKit

/// "Open Junk in Cabalmail." Foregrounds the app and drives the same
/// `navigateRequest` machinery as a notification tap; a cold launch parks
/// the request in `IntentBridge` until the session is wired.
struct OpenFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder"
    static let description = IntentDescription(
        "Opens a mail folder in Cabalmail.",
        categoryName: "Mail"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: MailFolderEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.requestOpenFolder(folder.id)
        return .result()
    }
}
#endif
