import XCTest
@testable import Cabalmail

// Regression coverage for issue #1508.
//
// A `Picker` placed inside a `Menu` renders as a submenu on macOS: the menu
// opens onto a single row carrying the picker's title, and the options sit
// one level below it. The feed item list's Order menu shipped that way, so
// choosing an ordering took a click, a hover and a second click, while the
// message list's Sort menu — built from top-level toggles — did not.
// `.pickerStyle(.inline)` flattens the options into the menu itself.
//
// Nothing tied the rule to the call site, so this suite walks the app
// sources and requires every `Picker` inside a `Menu` to ask for the inline
// style. Deleting `.pickerStyle(.inline)` from FeedItemListView.swift fails
// `testEveryMenuPickerIsInline` by path.
final class MenuPickerSourceScanTests: XCTestCase {

    func testEveryMenuPickerIsInline() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(
            sources.count, 40,
            "floor: an empty or mis-rooted scan would pass everything vacuously"
        )
        // Per-target floor: a target dropped out of the corpus is how a
        // clean file silently stands in for an offending one (#1207).
        for probe in ["Cabalmail/CabalmailApp.swift", "CabalmailMac/CabalmailMacApp.swift"] {
            XCTAssertNotNil(sources[probe], "\(probe) is missing from the corpus")
        }

        var inventory: [String: Int] = [:]
        var submenus: [String: Int] = [:]
        for (path, body) in sources {
            let pickers = try Self.menuPickers(in: body)
            guard !pickers.isEmpty else { continue }
            inventory[path] = pickers.count
            let nested = pickers.filter { !$0 }.count
            if nested > 0 { submenus[path] = nested }
        }

        // The menus that hold a picker today. A new one appearing here is
        // not a failure; a new one appearing in `submenus` is.
        XCTAssertEqual(
            inventory, ["Cabalmail/Views/FeedItemListView.swift": 1],
            "menu-picker inventory moved — check the new one is inline (#1508)"
        )
        XCTAssertEqual(
            submenus, [:],
            "a Picker inside a Menu is a submenu on macOS: add .pickerStyle(.inline) (#1508)"
        )
    }

    /// Proves the detector reads the reported shape, on synthetic snippets
    /// rather than on the corpus — so a rewrite of the views cannot quietly
    /// make the scan above vacuous.
    func testDetectorReadsTheReportedShapes() throws {
        let nested = """
            Menu {
                Picker("Order", selection: $model.ordering) {
                    Text("Newest first").tag(1)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            """
        XCTAssertEqual(try Self.menuPickers(in: nested), [false])

        let inline = """
            Menu {
                Picker("Order", selection: $model.ordering) {
                    Text("Newest first").tag(1)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            """
        XCTAssertEqual(try Self.menuPickers(in: inline), [true])

        // The style belongs to the picker; on the menu it changes nothing.
        let onTheMenu = nested + "\n.pickerStyle(.inline)"
        XCTAssertEqual(try Self.menuPickers(in: onTheMenu), [false])

        // Another style is still a submenu.
        let menuStyle = inline.replacingOccurrences(of: ".inline", with: ".menu")
        XCTAssertEqual(try Self.menuPickers(in: menuStyle), [false])

        // A closure among the picker's arguments must not be read as its
        // option list.
        let bindingArgument = """
            Menu {
                Picker("Order", selection: Binding(get: { value }, set: { value = $0 })) {
                    Text("A").tag(1)
                }
                .pickerStyle(.inline)
            } label: {
                Text("Order")
            }
            """
        XCTAssertEqual(try Self.menuPickers(in: bindingArgument), [true])

        // A picker outside any menu is a form control, not a menu row.
        XCTAssertEqual(try Self.menuPickers(in: "Picker(\"Theme\", selection: $theme) {\n}"), [])
        // Prose naming the shape is not the shape.
        XCTAssertEqual(try Self.menuPickers(in: "// Menu { Picker(\"Order\") {} }"), [])
    }

    // MARK: - Detector

    /// One entry per `Picker` inside a `Menu`'s content closure: whether the
    /// picker's own modifier chain asks for `.pickerStyle(.inline)`.
    private static func menuPickers(in body: String) throws -> [Bool] {
        let text = code(body)
        var found: [Bool] = []
        for menu in text.ranges(of: try Regex(#"\bMenu\s*\{"#)) {
            let menuOpen = text.index(before: menu.upperBound)
            guard let menuClose = matching("{", "}", in: text, from: menuOpen) else { continue }
            let content = text[menuOpen..<menuClose]
            for picker in content.ranges(of: try Regex(#"\bPicker\s*\("#)) {
                let argsOpen = text.index(before: picker.upperBound)
                guard let argsClose = matching("(", ")", in: text, from: argsOpen),
                      let optionsOpen = text[text.index(after: argsClose)...]
                          .firstIndex(where: { !$0.isWhitespace }),
                      text[optionsOpen] == "{",
                      let optionsClose = matching("{", "}", in: text, from: optionsOpen),
                      optionsClose < menuClose
                else { continue }
                let chain = modifierChain(text[text.index(after: optionsClose)..<menuClose])
                found.append(chain.contains(".pickerStyle(.inline)"))
            }
        }
        return found
    }

    /// The modifiers chained onto a view whose body just closed: the rest of
    /// the closing line, then each following line that starts with a dot.
    private static func modifierChain(_ tail: Substring) -> String {
        var chain: [String] = []
        for (index, line) in tail.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index > 0, !trimmed.hasPrefix(".") { break }
            chain.append(trimmed)
        }
        return chain.joined(separator: "\n")
    }

    /// The index of the bracket that closes the one at `start`.
    private static func matching(
        _ open: Character, _ close: Character, in text: String, from start: String.Index
    ) -> String.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            if text[index] == open {
                depth += 1
            } else if text[index] == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Line comments cut first: a comment naming the shape describes the
    /// rule, it does not break it.
    private static func code(_ body: String) -> String {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
    }

    /// Every Swift source in the iOS/visionOS and macOS app targets, keyed
    /// by its path under `apple/`. Rooted off this file's own compile-time
    /// path so the scan follows the checkout wherever it lives.
    private static func appSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        var found: [String: String] = [:]
        for target in ["Cabalmail", "CabalmailMac"] {
            let root = apple.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let key = url.standardizedFileURL.path
                    .replacingOccurrences(of: apple.standardizedFileURL.path + "/", with: "")
                found[key] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return found
    }
}
