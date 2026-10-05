import SwiftUI
import UniformTypeIdentifiers
import CabalmailKit

/// State behind the OPML import / export flows: which system panel is up,
/// the document being saved, and the result to report. Owned by whichever
/// view hosts `.feedOpmlFlows` (the feed sidebars, the Feeds settings).
@Observable
@MainActor
final class FeedOpmlController {
    var importerPresented = false
    var exporterPresented = false
    var exportDocument: OpmlDocument?
    var exportFilename = "cabalmail-feeds.opml"
    /// Folder the imported outline is rooted in; nil for top level.
    var importFolderId: String?
    /// Shown in an alert once an import or export finishes or fails.
    var resultMessage: String?

    func beginImport(into folderId: String? = nil) {
        importFolderId = folderId
        importerPresented = true
    }

    /// Fetches the OPML, then raises the save panel with it.
    func beginExport(management: FeedManagementViewModel) async {
        do {
            let export = try await management.exportOpml()
            exportDocument = OpmlDocument(text: export.opml)
            exportFilename = export.filename.isEmpty ? "cabalmail-feeds.opml" : export.filename
            exporterPresented = true
        } catch {
            resultMessage = FeedErrorText.describe(error)
        }
    }

    func finishImport(_ picked: Result<URL, Error>, management: FeedManagementViewModel) async {
        do {
            let url = try picked.get()
            let text = try Self.read(url)
            let result = try await management.importOpml(text, folderId: importFolderId)
            resultMessage = FeedOpmlSummary.text(for: result)
        } catch {
            resultMessage = FeedErrorText.describe(error)
        }
    }

    /// Reads a picked file inside its security scope (the picker grants
    /// access to that URL only for as long as we hold it).
    private static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}

/// The OPML text as a file, for the export panel.
struct OpmlDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.opml, .xml] }
    static var writableContentTypes: [UTType] { [.xml] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    /// `.opml` files identify as XML on most systems; this lets the open
    /// panel accept the extension whatever the type database says.
    static var opml: UTType { UTType(filenameExtension: "opml") ?? .xml }
}

/// One-paragraph result of an import, for the alert. Pure for tests.
enum FeedOpmlSummary {
    static func text(for result: RssOpmlImportResult) -> String {
        var parts: [String] = []
        parts.append(count(result.created, "new feed"))
        if result.existing > 0 { parts.append("\(count(result.existing, "feed")) already subscribed") }
        if result.foldersCreated > 0 { parts.append(count(result.foldersCreated, "folder") + " created") }
        var text = parts.joined(separator: ", ") + "."
        if !result.failed.isEmpty {
            let shown = result.failed.prefix(5).map { "\($0.url): \($0.message.isEmpty ? $0.code : $0.message)" }
            let more = result.failed.count > 5 ? " (and \(result.failed.count - 5) more)" : ""
            let headline = count(result.failed.count, "entry", plural: "entries") + " could not be added" + more
            text += "\n\n" + headline + ":\n" + shown.joined(separator: "\n")
        }
        return text
    }

    private static func count(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? noun : (plural ?? noun + "s"))"
    }
}

/// Hosts the system open and save panels and the result alert for OPML.
struct FeedOpmlFlows: ViewModifier {
    let controller: FeedOpmlController
    let management: FeedManagementViewModel?

    func body(content: Content) -> some View {
        @Bindable var controller = controller
        content
            .fileImporter(isPresented: $controller.importerPresented,
                          allowedContentTypes: [.opml, .xml, .plainText]) { picked in
                guard let management else { return }
                Task { await controller.finishImport(picked, management: management) }
            }
            .fileExporter(isPresented: $controller.exporterPresented, document: controller.exportDocument,
                          contentType: .xml, defaultFilename: controller.exportFilename) { outcome in
                if case .failure(let error) = outcome { controller.resultMessage = error.localizedDescription }
            }
            .alert("Feeds", isPresented: resultBinding) {
                Button("OK") { controller.resultMessage = nil }
            } message: {
                Text(controller.resultMessage ?? "")
            }
    }

    private var resultBinding: Binding<Bool> {
        Binding(get: { controller.resultMessage != nil },
                set: { if !$0 { controller.resultMessage = nil } })
    }
}

extension View {
    func feedOpmlFlows(_ controller: FeedOpmlController, management: FeedManagementViewModel?) -> some View {
        modifier(FeedOpmlFlows(controller: controller, management: management))
    }
}
