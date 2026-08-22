import XCTest

/// Regression cover for #1222: `key` handed its token straight to `typeKey`,
/// so anything longer than one character raised an XCTest failure and took the
/// REPL down with it — and a return, which has no spelling that survives the
/// exchange file's whitespace trim, was unreachable by any route.
///
/// The two halves are asserted separately because they failed separately: the
/// resolution tests say a name now reaches XCTest as the right key, and the
/// rejection tests say an unknown token never reaches XCTest at all.
final class KeyStrokeTests: XCTestCase {

    // MARK: - A literal character still works

    func testSingleCharacterTokenIsALiteral() {
        XCTAssertEqual(KeyStrokeTable.stroke(for: "v"), .character("v"))
        XCTAssertEqual(KeyStrokeTable.stroke(for: "a"), .character("a"))
        XCTAssertEqual(KeyStrokeTable.stroke(for: "1"), .character("1"))
    }

    /// A one-character token is passed through verbatim, case included — `key
    /// V` is not `key v`.
    func testSingleCharacterTokenKeepsItsCase() {
        XCTAssertEqual(KeyStrokeTable.stroke(for: "V"), .character("V"))
    }

    // MARK: - Named keys resolve

    func testReturnResolvesToTheKeyboardsReturn() {
        XCTAssertEqual(KeyStrokeTable.stroke(for: "return"), .named(XCUIKeyboardKey.return))
    }

    func testEveryNameInTheTableResolvesToItsOwnKey() {
        for (name, key) in KeyStrokeTable.names {
            XCTAssertEqual(
                KeyStrokeTable.stroke(for: name), .named(key),
                "'\(name)' should resolve to its own table entry"
            )
        }
    }

    func testNamesAreCaseInsensitive() {
        XCTAssertEqual(KeyStrokeTable.stroke(for: "RETURN"), .named(XCUIKeyboardKey.return))
        XCTAssertEqual(KeyStrokeTable.stroke(for: "PageUp"), .named(XCUIKeyboardKey.pageUp))
    }

    /// The two spellings that used to kill the runner. `\n` is what a shell
    /// hands over when a recipe author writes the escape, and `\e` was the
    /// other documented REPL-killer.
    func testShellEscapeSpellingsResolveRatherThanKillingTheRunner() {
        XCTAssertEqual(KeyStrokeTable.stroke(for: #"\n"#), .named(XCUIKeyboardKey.return))
        XCTAssertEqual(KeyStrokeTable.stroke(for: #"\r"#), .named(XCUIKeyboardKey.return))
        XCTAssertEqual(KeyStrokeTable.stroke(for: #"\t"#), .named(XCUIKeyboardKey.tab))
        XCTAssertEqual(KeyStrokeTable.stroke(for: #"\e"#), .named(XCUIKeyboardKey.escape))
    }

    // MARK: - Unknown tokens are rejected, not forwarded

    /// The fatal case. Every one of these is more than one character, so the
    /// old code handed it to `typeKey` and XCTest threw. Nil is the verb's cue
    /// to raise a `DriveError` instead.
    func testUnknownMultiCharacterTokenIsRejected() {
        for token in ["retrun", "banana", "returnn", "ret", "cmd+v", ""] {
            XCTAssertNil(
                KeyStrokeTable.stroke(for: token),
                "'\(token)' must not reach typeKey"
            )
        }
    }

    // MARK: - Only the mechanism that needs focus asks for it (#1230)

    /// The defect. A named key can only be delivered by `typeText`, which is
    /// fatal to the REPL with nothing focused, so every stroke that resolves
    /// to a name has to declare it needs focus first.
    func testEveryNamedStrokeRequiresKeyboardFocus() {
        for (name, _) in KeyStrokeTable.names {
            XCTAssertEqual(
                KeyStrokeTable.stroke(for: name)?.requiresKeyboardFocus, true,
                "'\(name)' goes out through typeText and must be guarded"
            )
        }
        for (alias, _) in KeyStrokeTable.escapeAliases {
            XCTAssertEqual(
                KeyStrokeTable.stroke(for: alias)?.requiresKeyboardFocus, true,
                "'\(alias)' goes out through typeText and must be guarded"
            )
        }
    }

    /// The control, and the half a blunter fix would have broken: `key q` with
    /// nothing focused was never fatal, because `typeKey` tolerates an
    /// unfocused app. Guarding it too would refuse a command that works.
    func testACharacterStrokeDoesNotRequireKeyboardFocus() {
        for token in ["q", "v", "1", "V"] {
            XCTAssertEqual(
                KeyStrokeTable.stroke(for: token)?.requiresKeyboardFocus, false,
                "'\(token)' goes out through typeKey and needs no focus"
            )
        }
    }

    /// The split itself, stated once so neither half can drift into the other:
    /// requiring focus is exactly what tells the two cases apart.
    func testRequiringFocusIsExactlyTheNamedCase() {
        for token in ["q", "v", "1"] + KeyStrokeTable.names.map(\.key) {
            guard let stroke = KeyStrokeTable.stroke(for: token) else {
                return XCTFail("'\(token)' should resolve")
            }
            switch stroke {
            case .character:
                XCTAssertFalse(stroke.requiresKeyboardFocus, "'\(token)' is a character")
            case .named:
                XCTAssertTrue(stroke.requiresKeyboardFocus, "'\(token)' is a name")
            }
        }
    }

    // MARK: - The table cannot go vacuous

    /// The one-character rule runs first, so a single-character name would be
    /// shadowed and silently typed as a literal. Nothing in the table may be
    /// one character.
    func testNoNamedKeyIsASingleCharacter() {
        for (name, _) in KeyStrokeTable.names {
            XCTAssertGreaterThan(name.count, 1, "'\(name)' would be shadowed by the literal rule")
        }
        for (alias, _) in KeyStrokeTable.escapeAliases {
            XCTAssertGreaterThan(alias.count, 1, "'\(alias)' would be shadowed by the literal rule")
        }
    }

    /// Names are matched lowercased, so an upper-case table entry could never
    /// be reached.
    func testEveryNameIsStoredLowercased() {
        for (name, _) in KeyStrokeTable.names {
            XCTAssertEqual(name, name.lowercased(), "'\(name)' is unreachable")
        }
    }

    /// A floor, so a future edit that empties the table fails here rather than
    /// making every rejection test pass vacuously.
    func testTableCoversTheKeysRecipesNeed() {
        XCTAssertGreaterThanOrEqual(KeyStrokeTable.names.count, 15)
        for required in ["return", "tab", "escape", "space", "delete"] {
            XCTAssertNotNil(KeyStrokeTable.stroke(for: required))
        }
    }

    /// The rejection message quotes the vocabulary back, so it has to list it.
    func testHelpNamesListsEveryName() {
        let help = KeyStrokeTable.helpNames
        for (name, _) in KeyStrokeTable.names {
            XCTAssertTrue(help.contains(name), "'\(name)' missing from the help list")
        }
    }
}
