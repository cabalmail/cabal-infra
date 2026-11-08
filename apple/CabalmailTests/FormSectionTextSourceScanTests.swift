import Foundation
import XCTest

/// Every form section header and footer is drawn by `FormSectionHeader` /
/// `FormSectionFooter`, so it scales with the interface text size in the
/// form's own style. One left bare is set by the scene root's default font
/// instead: a bold header turns into body text, a small footer into body
/// text, at every size but Medium (seen on the sign-in and Settings forms
/// before this held). `AppFontContainerTests` proves what the wrappers do;
/// this proves nobody skips them. `Section("Title")` is the SwiftLint
/// rule's (`string_titled_section`).
final class FormSectionTextSourceScanTests: XCTestCase {
    /// Headers that are not a form's: the sidebar's section headers, which
    /// size their own text (`appFontWhenScaled` in `sectionHeader`).
    private static let sidebarHeaders: [String: Int] = [
        "CabalmailUI/Mail/Folders/FolderListView.swift": 1,
        "CabalmailUI/Mail/Folders/FolderListView+Helpers.swift": 1,
    ]

    func testEveryFormHeaderAndFooterIsWrapped() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 40, "floor: an empty scan would pass vacuously")

        var wrapped = 0
        var bare: [String: Int] = [:]
        for (name, body) in sources {
            let closures = Self.closures(in: body)
            wrapped += closures.filter(\.isWrapped).count
            let unwrapped = closures.filter { !$0.isWrapped }.count
            if unwrapped > 0 { bare[name] = unwrapped }
        }
        XCTAssertGreaterThan(wrapped, 40, "floor: the forms carry more than 40 headers and footers")
        XCTAssertEqual(bare, Self.sidebarHeaders,
                       "draw a form section's header or footer through FormSectionHeader / FormSectionFooter")
    }

    /// The detector sees a bare closure as bare and a wrapped one as
    /// wrapped, a comment in front of the wrapper included, so the scan
    /// above can't pass by matching nothing.
    func testDetectorSeesBareAndWrappedClosures() {
        let bare = """
        Section { row } header: {
            Text("Server")
        } footer: {
            Text("Explained.").sectionFooter()
        }
        """
        let wrapped = """
        Section { row } header: {
            // Where the fields start.
            FormSectionHeader {
                Text("Server")
            }
        } footer: { FormSectionFooter { Text("Explained.") } }
        """
        XCTAssertEqual(Self.closures(in: bare).map(\.isWrapped), [false, false])
        XCTAssertEqual(Self.closures(in: wrapped).map(\.isWrapped), [true, true])
    }

    // MARK: - Scanning

    private struct Closure {
        let kind: String
        let firstToken: String
        var isWrapped: Bool {
            firstToken == (kind == "header" ? "FormSectionHeader" : "FormSectionFooter")
        }
    }

    /// Each `} header: {` / `} footer: {` closure and the first identifier
    /// inside it, past any line comments.
    private static func closures(in source: String) -> [Closure] {
        let pattern = #"\}\s*(header|footer):\s*\{\s*(?://[^\n]*\n\s*)*([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let kind = Range(match.range(at: 1), in: source),
                  let token = Range(match.range(at: 2), in: source) else { return nil }
            return Closure(kind: String(source[kind]), firstToken: String(source[token]))
        }
    }

    private static func appSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        var found: [String: String] = [:]
        for target in ["CabalmailUI", "CabalmailMac"] {
            let root = apple.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let key = url.standardizedFileURL.path
                    .replacingOccurrences(of: apple.standardizedFileURL.path + "/", with: "")
                found[key] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return found
    }
}
