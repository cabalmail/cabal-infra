import XCTest
@testable import CabalmailUI

// Regression coverage for issue #1914, the other half of #1201's defect.
//
// `ConfirmationDialogRoleTests` forbids a dialog from answering the role
// question itself (`role: .cancel`, which SwiftUI drops everywhere but
// macOS). It says nothing about a dialog that declares no back-out button at
// all, and six did: three in `FeedManagementActions`, one each in
// `FeedSubscriptionSettingsSheet`, `FeedItemListView` and
// `FlagPaletteSettingsView`. Four of the six had a destructive action as
// their only declared button — the exact state `ConfirmationDialogPolicy`'s
// doc comment describes, one labelled control on screen and it is the
// irreversible one, under a message saying it cannot be undone.
//
// Fourteen siblings in the same tree did declare the button, so this was a
// gap rather than a style choice; the invariant below is what connects the
// policy to the call sites that have to consult it.
final class ConfirmationDialogBackOutScanTests: XCTestCase {

    /// Every `confirmationDialog` in the app targets, and every
    /// `confirmationPrompt` (the shared app layer's wrapper, which presents
    /// the same actions as an alert in book pose), declares a button that
    /// backs out, and it asks the policy for its role.
    func testEveryConfirmationDialogDeclaresABackOut() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(
            sources.count, 40,
            "floor: an empty or mis-rooted scan would pass everything vacuously"
        )
        // Per-target probes, for the reason #1207 recorded: a target outside
        // the corpus is a target the invariant cannot see.
        for probe in [
            "Cabalmail/CabalmailApp.swift",
            "CabalmailUI/Shell/ContentView.swift",
            "CabalmailMac/CabalmailMacApp.swift",
            "CabalmailWatch/ContentView.swift",
        ] {
            XCTAssertNotNil(sources[probe], "\(probe) is missing from the corpus")
        }

        var dialogs = 0
        var offenders: [String] = []
        for (name, body) in sources {
            for actions in DialogActionsScanner.actions(in: body, resolvingIn: Array(sources.values)) {
                dialogs += 1
                guard !actions.contains("backOutRole") else { continue }
                if Self.choiceDrivenDialogs.contains(name) || Self.forwardingDialogs.contains(name) { continue }
                offenders.append(name)
            }
        }
        Self.assertExemptionsHold(in: sources)

        // The corpus holds more dialogs than #1201 and #1914 between them
        // touched; a scan that found a handful would be reading something
        // other than this tree.
        XCTAssertGreaterThan(dialogs, 15, "too few dialogs found to be scanning the app")
        XCTAssertEqual(
            offenders, [],
            "a confirmationDialog must declare a back-out button with "
            + "ConfirmationDialogPolicy.backOutRole (#1914)"
        )
    }

    /// Proves the detector catches the reported shape, on synthetic snippets
    /// rather than on the corpus — so a future rewrite of these views cannot
    /// quietly make the invariant vacuous.
    func testDetectorReadsTheActionsClosureOnly() {
        let missing = """
        .confirmationDialog("Unsubscribe?", isPresented: $x, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { go() }
        } message: {
            Text("Gone for good.")
        }
        """
        let present = """
        .confirmationDialog("Unsubscribe?", isPresented: $x, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { go() }
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
        } message: {
            Text("Gone for good.")
        }
        """
        // The trap a laxer scan falls into: the word is in the file, in the
        // dialog, and in the wrong closure.
        let elsewhere = """
        .confirmationDialog("Unsubscribe?", isPresented: $x, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { go() }
        } message: {
            Text("backOutRole")
        }
        """
        for (label, source, expected) in [
            ("missing", missing, false), ("present", present, true), ("elsewhere", elsewhere, false)
        ] {
            let closures = DialogActionsScanner.actions(in: source)
            XCTAssertEqual(closures.count, 1, "\(label): one dialog expected")
            XCTAssertEqual(
                closures.first?.contains("backOutRole"), expected,
                "\(label): detector read the wrong closure"
            )
        }
        // A title holding a brace or a paren does not end the scan early.
        let awkward = """
        .confirmationDialog(Text("Delete {x} (really)?"), isPresented: $x) {
            Button("Delete", role: .destructive) { go() }
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
        }
        """
        XCTAssertEqual(DialogActionsScanner.actions(in: awkward).first?.contains("backOutRole"), true)

        // The wrapper takes the same shapes, and is read the same way.
        let prompt = missing.replacingOccurrences(of: ".confirmationDialog(", with: ".confirmationPrompt(")
        XCTAssertEqual(DialogActionsScanner.actions(in: prompt), DialogActionsScanner.actions(in: missing))
        let both = present + "\n" + prompt
        let declared = DialogActionsScanner.actions(in: both).map { $0.contains("backOutRole") }
        XCTAssertEqual(declared.count, 2, "one dialog and one prompt expected")
        XCTAssertEqual(declared.filter { $0 }.count, 1, "the prompt's missing back-out went unread")
    }

    /// The other call shape in the tree: the actions are a named
    /// `@ViewBuilder` rather than a trailing closure, which an earlier cut of
    /// this scan reported as four missing buttons that are all there.
    func testDetectorResolvesANamedActionsBuilder() {
        let resolved = """
        .confirmationDialog(
            title, isPresented: $x, presenting: pending,
            actions: revokeDialogActions, message: revokeDialogMessage
        )

        @ViewBuilder
        private func revokeDialogActions(for address: Address) -> some View {
            Button("Revoke", role: .destructive) { go() }
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
        }

        @ViewBuilder
        private func revokeDialogMessage(for address: Address) -> some View {
            Text("backOutRole")
        }
        """
        XCTAssertEqual(DialogActionsScanner.actions(in: resolved).first?.contains("backOutRole"), true)

        let missing = resolved.replacingOccurrences(
            of: """
                Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
            """,
            with: ""
        )
        XCTAssertEqual(
            DialogActionsScanner.actions(in: missing).first?.contains("backOutRole"), false,
            "the message builder's copy of the word satisfied the scan"
        )

        // A name the file does not declare resolves to nothing, which is
        // reported rather than skipped.
        let unresolvable = """
        .confirmationDialog(title, isPresented: $x, actions: thereIsNoSuchBuilder)
        """
        XCTAssertEqual(DialogActionsScanner.actions(in: unresolvable), [""])

        // And the builder may live one file over, as `FolderListView`'s does
        // in its `+Helpers` extension.
        let helper = """
        extension FolderListView {
            @ViewBuilder
            func deleteDialogActions(for folder: Folder) -> some View {
                Button("Delete", role: .destructive) { go() }
                Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
            }
        }
        """
        let host = """
        .confirmationDialog(title, isPresented: $x, actions: deleteDialogActions, message: m)
        """
        XCTAssertEqual(
            DialogActionsScanner.actions(in: host, resolvingIn: [host, helper]).first?.contains("backOutRole"),
            true,
            "a builder in a sibling file reads as a missing button"
        )
        XCTAssertEqual(DialogActionsScanner.actions(in: host).first, "", "same-file resolution invented a body")
    }

    // MARK: - Corpus

    /// The dialogs that build their buttons from `ComposeCancelChoice`
    /// rather than declaring them one by one: the choice carries
    /// `ConfirmationDialogPolicy.backOutRole` itself (`keepEditing`, pinned
    /// by `ConfirmationDialogRoleTests`), so the word is in the enum and not
    /// at the call site. Both halves of that are checked above rather than
    /// taken on trust.
    private static let choiceDrivenDialogs: Set<String> = ["CabalmailUI/Compose/ComposeView.swift"]

    /// The wrapper behind every `confirmationPrompt`: its one
    /// `confirmationDialog` (and its `.alert`) forward the caller's actions,
    /// which the scan reads at the caller, so it has no buttons of its own to
    /// check. That it still forwards rather than declares is checked above.
    private static let forwardingDialogs: Set<String> = ["CabalmailUI/Platform/ConfirmationPrompt.swift"]

    /// Both exemptions are checked rather than taken on trust: each exempted
    /// file is still in the corpus, and still has the shape that earns it.
    private static func assertExemptionsHold(in sources: [String: String],
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
        let exempted = choiceDrivenDialogs.union(forwardingDialogs)
        XCTAssertEqual(
            Set(sources.keys).intersection(exempted), exempted,
            "an exempted file left the corpus, so its exemption is no longer checked",
            file: file, line: line
        )
        for name in choiceDrivenDialogs {
            XCTAssertTrue(
                sources[name]?.contains("ComposeCancelChoice") ?? false,
                "\(name) no longer builds its buttons from ComposeCancelChoice, so it owes the scan a literal back-out",
                file: file, line: line
            )
        }
        for name in forwardingDialogs {
            let body = sources[name] ?? ""
            XCTAssertTrue(
                body.contains("ConfirmationDialogPolicy.presentsAsAlert("),
                "\(name) no longer asks the policy which style to present, "
                + "so it is not the fold wrapper the exemption describes",
                file: file, line: line
            )
            XCTAssertFalse(
                body.contains("Button("),
                "\(name) declares a button of its own, so it owes the scan a back-out like any other dialog",
                file: file, line: line
            )
        }
    }

    /// Every Swift source in the app targets, keyed by its path under
    /// `apple/` — `ConfirmationDialogRoleTests`' corpus, for the same reason
    /// it gives: a filename key would let one target's `ContentView.swift`
    /// stand in for another's.
    private static func appSources() throws -> [String: String] {
        let apple = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CabalmailTests
            .deletingLastPathComponent()   // apple
        var found: [String: String] = [:]
        for target in ["Cabalmail", "CabalmailUI", "CabalmailMac", "CabalmailWatch"] {
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

/// The scan's parser: finds each dialog's actions in Swift source without
/// compiling it. A type of its own so the suite above holds the
/// invariants and this holds the reading.
private enum DialogActionsScanner {
    /// What each `confirmationDialog` or `confirmationPrompt` in `body`
    /// declares as its actions: the trailing closure after the modifier's
    /// own parentheses, or — for the `actions:` parameter form — the body of
    /// the named `@ViewBuilder` it points at, resolved in the same file.
    /// Never the `message:` closure, which is where a lazier scan would find
    /// the word it is looking for.
    static func actions(in body: String, resolvingIn corpus: [String]? = nil) -> [String] {
        let sources = corpus ?? [body]
        let chars = Array(body)
        var found: [String] = []
        for modifier in [".confirmationDialog(", ".confirmationPrompt("] {
            found += actions(of: modifier, in: body, chars: chars, resolvingIn: sources)
        }
        return found
    }

    private static func actions(of modifier: String,
                                in body: String,
                                chars: [Character],
                                resolvingIn sources: [String]) -> [String] {
        var found: [String] = []
        var index = body.startIndex
        while let call = body.range(of: modifier, range: index..<body.endIndex) {
            index = call.upperBound
            let open = body.distance(from: body.startIndex, to: call.upperBound) - 1
            guard let closeParen = matchingDelimiter(chars, from: open, open: "(", close: ")") else { continue }
            let arguments = String(chars[chars.index(after: open)..<closeParen])
            if let builder = namedActionsBuilder(in: arguments) {
                found.append(builderBody(named: builder, in: [body] + sources) ?? "")
                continue
            }
            if arguments.contains("actions:") {
                // An inline `actions:` closure: the parentheses hold it.
                found.append(arguments)
                continue
            }
            guard let openBrace = chars[chars.index(after: closeParen)...].firstIndex(of: "{"),
                  let closeBrace = matchingDelimiter(chars, from: openBrace, open: "{", close: "}")
            else { continue }
            found.append(String(chars[chars.index(after: openBrace)..<closeBrace]))
        }
        return found
    }

    /// The identifier an `actions:` argument names, when it names one rather
    /// than spelling the buttons out inline.
    private static func namedActionsBuilder(in arguments: String) -> String? {
        guard let match = arguments.firstMatch(of: /actions:\s*([A-Za-z_][A-Za-z0-9_]*)/)
        else { return nil }
        return String(match.1)
    }

    /// The body of the `func`/`var` a dialog's `actions:` argument names,
    /// looked for across the whole corpus rather than in the dialog's own
    /// file: `FolderListView`'s builder lives in its `+Helpers` extension,
    /// one file over. An unresolvable name yields nil and the dialog is
    /// reported, which is the safe direction for a scan whose whole job is
    /// to find a missing button.
    private static func builderBody(named builder: String, in sources: [String]) -> String? {
        for body in sources {
            let chars = Array(body)
            for keyword in ["func \(builder)", "var \(builder)"] {
                guard let declaration = body.range(of: keyword) else { continue }
                let start = body.distance(from: body.startIndex, to: declaration.upperBound)
                guard let openBrace = chars[start...].firstIndex(of: "{"),
                      let closeBrace = matchingDelimiter(chars, from: openBrace, open: "{", close: "}")
                else { continue }
                return String(chars[chars.index(after: openBrace)..<closeBrace])
            }
        }
        return nil
    }

    /// Index of the delimiter closing the one at `start`, skipping string
    /// literals so a title containing a brace cannot end the scan early.
    private static func matchingDelimiter(_ chars: [Character],
                                          from start: Int,
                                          open: Character,
                                          close: Character) -> Int? {
        var depth = 0
        var inString = false
        var index = start
        while index < chars.count {
            let character = chars[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}
