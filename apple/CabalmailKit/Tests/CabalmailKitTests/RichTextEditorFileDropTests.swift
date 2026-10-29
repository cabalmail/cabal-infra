import XCTest
#if canImport(WebKit)
import WebKit
@testable import CabalmailKit
import CabalmailKitTestSupport

/// Files dropped or pasted onto the composer's editor page
/// (`EditorFileDrops`), and the images the host shows inline there
/// (`InlineImageSchemeHandler`). Against the live editor page, like the
/// conversion suite, and carved out of CI's simulator legs with it
/// (apple.yml): a freshly created simulator never launches a WebContent
/// process under a hostless runner, so the macOS leg carries these.
@MainActor
final class RichTextEditorFileDropTests: XCTestCase {
    private var controller: RichTextEditorController!

    /// A 1×1 PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
    private static let handler = #"<img src="cabal-probe.png" onerror="window.__cabalProbe = 'ran'">"#

    override func setUp() async throws {
        try await super.setUp()
        // See RichTextEditorControllerTests.setUp: a cold runner takes far
        // longer than the production timeout to boot its first page.
        controller = RichTextEditorController(readyTimeout: 120)
        await controller.waitUntilReady()
        XCTAssertNil(controller.bridgeFailure, "editor bridge never booted in this runner")
    }

    override func tearDown() async throws {
        controller = nil
        try await super.tearDown()
    }

    /// Dropped files (a message from a list, an image) are the host's: the
    /// page says they are coming, hands each one's bytes over in turn, and
    /// keeps WebKit from inserting them.
    func testDroppedFilesGoToTheHostAndNotIntoThePage() async throws {
        let drops = DropRecorder(controller)
        let eml = "From: sender@example.invalid\r\n\r\nHello"
        let files = [DropFile(name: "note.eml", contents: eml), DropFile(name: "photo.png", contents: "png")]

        let dropped = try await drop(files)

        XCTAssertTrue(dropped.prevented, "the page left the files to WebKit's own insertion")
        try await waitUntilOnMainActor { drops.files.count == 2 }
        XCTAssertEqual(drops.started, [2], "the page did not say the files were coming")
        XCTAssertEqual(drops.files.map(\.name), ["note.eml", "photo.png"])
        XCTAssertEqual(drops.files.map(\.contents), [.data(Data(eml.utf8)), .data(Data("png".utf8))])
    }

    /// A drag that carries markup as well as files is a selection from a
    /// page or a document: its markup takes the paste path, and nothing is
    /// handed over.
    func testADropCarryingMarkupInsertsItAndHandsNothingOver() async throws {
        let drops = DropRecorder(controller)
        let markup = "<p><b>dropped</b>\(Self.handler)</p>"

        let dropped = try await drop([DropFile(name: "photo.png", contents: "png")], html: markup)

        XCTAssertTrue(dropped.html.contains("<b>dropped</b>"), dropped.html)
        XCTAssertFalse(dropped.html.contains("onerror"), dropped.html)
        let handed = await holdsOnMainActor(within: 0.5) { !drops.started.isEmpty || !drops.files.isEmpty }
        XCTAssertFalse(handed, "a selection's file was handed over")
    }

    /// A file too large to send across the bridge is refused unread, and the
    /// files dropped with it still come.
    func testAFileOverTheLimitIsRefusedUnread() async throws {
        let drops = DropRecorder(controller)

        _ = try await drop([DropFile(name: "film.mov", size: 50_000_001), DropFile(name: "notes.txt", contents: "ok")])

        try await waitUntilOnMainActor { drops.files.count == 2 }
        XCTAssertEqual(drops.files.map(\.contents), [.tooLarge(limitBytes: 50_000_000), .data(Data("ok".utf8))])
    }

    /// A pasted image goes to the host like a dropped one. Inserting the
    /// paste's text flavor instead pasted nothing.
    func testAPastedImageGoesToTheHost() async throws {
        let drops = DropRecorder(controller)

        let prevented = try await paste(DropFile(name: "image.png", base64: Self.png.base64EncodedString()))

        XCTAssertTrue(prevented)
        try await waitUntilOnMainActor { drops.files.count == 1 }
        XCTAssertEqual(drops.files.first?.contents, .data(Self.png))
    }

    /// The host shows two dropped images inline: each goes where they were
    /// dropped, in order, as the `cid:` the message will carry, loaded from
    /// the host, and the edit counts as one (`input`).
    func testPlacedImagesShowInOrderAsTheirContentIDs() async throws {
        await controller.setHTML("<p>Before</p>")
        let drops = DropRecorder(controller)
        var edited = false
        controller.onContentChanged = { edited = true }
        controller.inlineImages.provider = { _ in (Self.png, "image/png") }
        let png = Self.png.base64EncodedString()

        _ = try await drop([DropFile(name: "a.png", base64: png), DropFile(name: "b.png", base64: png)])
        try await waitUntilOnMainActor { drops.files.count == 2 }
        let placedFirst = await controller.fileDrops.placeImage(drops.files[0], contentID: "a@cabalmail", alt: "a.png")
        let placedSecond = await controller.fileDrops.placeImage(drops.files[1], contentID: "b@cabalmail", alt: "b.png")

        XCTAssertTrue(placedFirst)
        XCTAssertTrue(placedSecond)
        let html = await controller.getHTML()
        let first = try XCTUnwrap(html.range(of: #"src="cid:a@cabalmail""#), html)
        let second = try XCTUnwrap(html.range(of: #"src="cid:b@cabalmail""#), html)
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "the images swapped places")
        XCTAssertTrue(html.hasPrefix("<p>Before"), html)
        try await waitUntilOnMainActor {
            try await self.controller.webView.evaluateJavaScript(
                "Array.from(document.images).filter(function (img) { return img.naturalWidth > 0; }).length"
            ) as? Int == 2
        }
        try await waitUntilOnMainActor { edited }
    }

    /// The page shows only a `cid:` image the host names, for a file it
    /// handed over: nothing else can use it to put an image in.
    func testThePagePlacesOnlyACidImageForAFileItHandedOver() async throws {
        let drops = DropRecorder(controller)
        _ = try await drop([DropFile(name: "a.png", base64: Self.png.base64EncodedString())])
        try await waitUntilOnMainActor { drops.files.count == 1 }
        let file = try XCTUnwrap(drops.files.first)

        let remote = try await controller.webView.evaluateJavaScript(
            "window.cabal.placeDroppedImage(\(file.id), 'https://tracker.invalid/a.png', '')"
        ) as? Bool
        let unknown = await controller.fileDrops.placeImage(
            EditorFileDrops.File(id: 999, name: "", contents: .unreadable), contentID: "b@cabalmail", alt: ""
        )

        XCTAssertEqual(remote, false)
        XCTAssertFalse(unknown)
        let html = await controller.getHTML()
        XCTAssertFalse(html.contains("<img"), html)
    }

    /// A file the host attaches instead leaves no place behind.
    func testAForgottenFileCannotBePlaced() async throws {
        let drops = DropRecorder(controller)
        _ = try await drop([DropFile(name: "a.png", base64: Self.png.base64EncodedString())])
        try await waitUntilOnMainActor { drops.files.count == 1 }
        let file = try XCTUnwrap(drops.files.first)

        await controller.fileDrops.forget(file)
        let placed = await controller.fileDrops.placeImage(file, contentID: "a@cabalmail", alt: "")

        XCTAssertFalse(placed)
    }

    /// WebKit leaves `cid:` to the app, which is what lets the editor show
    /// an inline image as the reference the message carries.
    func testWebKitLeavesTheCidSchemeToTheApp() {
        XCTAssertFalse(WKWebView.handlesURLScheme("cid"))
    }

    func testACidURLNamesItsContentID() throws {
        let contentID = InlineImageSchemeHandler.contentID(of:)
        XCTAssertEqual(contentID(try XCTUnwrap(URL(string: "cid:a1@cabalmail"))), "a1@cabalmail")
        XCTAssertEqual(contentID(try XCTUnwrap(URL(string: "CID:part%201@x"))), "part 1@x")
        XCTAssertNil(contentID(try XCTUnwrap(URL(string: "https://x.example/a.png"))))
        XCTAssertNil(contentID(try XCTUnwrap(URL(string: "cid:"))))
    }

    // MARK: Helpers

    /// Puts the caret at the end of the editor and fires a `drop` carrying
    /// `files`, as WebKit does for files dragged in from outside the page,
    /// with `html` alongside them if given. Returns the editor's markup and
    /// whether the page kept WebKit from handling the drop.
    private func drop(_ files: [DropFile], html: String? = nil) async throws -> (html: String, prevented: Bool) {
        let read = try await controller.webView.evaluateJavaScript(
            """
            (function (files, html) {
              \(Self.caretAtEnd)
              const data = new DataTransfer();
              files.forEach(function (file) { data.items.add(\(Self.makeFile)); });
              if (html !== null) data.setData('text/html', html);
              const init = { bubbles: true, cancelable: true, dataTransfer: data };
              const event = new (window.DragEvent || MouseEvent)('drop', init);
              if (event.dataTransfer !== data) Object.defineProperty(event, 'dataTransfer', { value: data });
              editor.dispatchEvent(event);
              return [editor.innerHTML, event.defaultPrevented];
            })(\(Self.encode(files)), \(html.map(Self.jsonString) ?? "null"))
            """
        ) as? [Any]
        let markup = try XCTUnwrap(read?.first as? String)
        let prevented = try XCTUnwrap(read?.last as? Bool)
        return (markup, prevented)
    }

    /// Fires a `paste` carrying one file and no markup. Returns whether the
    /// page kept WebKit from handling it.
    private func paste(_ file: DropFile) async throws -> Bool {
        let prevented = try await controller.webView.evaluateJavaScript(
            """
            (function (files) {
              \(Self.caretAtEnd)
              const data = new DataTransfer();
              const file = files[0];
              data.items.add(\(Self.makeFile));
              const event = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: data });
              if (event.clipboardData !== data) Object.defineProperty(event, 'clipboardData', { value: data });
              editor.dispatchEvent(event);
              return event.defaultPrevented;
            })(\(Self.encode([file])))
            """
        ) as? Bool
        return try XCTUnwrap(prevented)
    }

    private static let caretAtEnd = """
        const editor = document.getElementById('editor');
        editor.focus();
        const range = document.createRange();
        range.selectNodeContents(editor);
        range.collapse(false);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        """

    /// A `File` from one `encode(_:)` entry: [name, text, size, base64].
    private static let makeFile = """
        (function () {
          const parts = file[3] !== null
            ? [Uint8Array.from(atob(file[3]), function (c) { return c.charCodeAt(0); })]
            : [file[1]];
          if (file[3] === null && file[2] > file[1].length) parts.push(new Uint8Array(file[2] - file[1].length));
          return new File(parts, file[0]);
        })()
        """

    private static func encode(_ files: [DropFile]) -> String {
        let entries = files.map { file in
            "[\(jsonString(file.name)), \(jsonString(file.contents)), \(file.size), "
                + "\(file.base64.map(jsonString) ?? "null")]"
        }
        return "[\(entries.joined(separator: ", "))]"
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data()
        return String(String(data: data, encoding: .utf8)?.dropFirst().dropLast() ?? "\"\"")
    }
}

/// A file for the drop and paste helpers: text `contents` padded with zero
/// bytes to `size` if that is longer, or the bytes `base64` decodes to.
private struct DropFile {
    let name: String
    var contents = ""
    var size = 0
    var base64: String?
}

/// What a controller tells its host about files dropped onto the editor.
@MainActor
private final class DropRecorder {
    private(set) var started: [Int] = []
    private(set) var files: [EditorFileDrops.File] = []

    init(_ controller: RichTextEditorController) {
        controller.fileDrops.onStarted = { [weak self] in self?.started.append($0) }
        controller.fileDrops.onFile = { [weak self] in self?.files.append($0) }
    }
}
#endif
