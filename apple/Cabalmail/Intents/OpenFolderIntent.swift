#if os(iOS)
import AppIntents
import CabalmailKit

/// "Open Junk in Cabalmail." Foregrounds the app and opens the folder in
/// the window last used, as a notification tap opens its message
/// (`DeepLinkRouter`); a cold launch parks it for the first window.
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
