import XCTest

/// The `key` verb's token vocabulary, kept as a pure value so the rule it
/// enforces is testable without a simulator (#1222).
///
/// `key` used to hand its first token straight to `typeKey(_ key: String,
/// modifierFlags:)`, which accepts exactly one character. Anything longer is
/// an `NSInvalidArgumentException` — an XCTest *failure* rather than a Swift
/// error, so it unwinds `testDriveLoop` and every queued command afterwards
/// answers `runner is gone`. The two spellings a recipe author reaches for
/// first, `key \n` and `key \e`, are both two characters after the shell is
/// done with them, so both cost a REPL restart.
///
/// A return was unreachable by any spelling. The exchange file's whole line is
/// trimmed of whitespace before the verb sees it, so a genuine one-character
/// carriage return (`key $(printf '\r')`) is gone by the time `key` runs and
/// the verb answers with its grammar error. Trimming is right — the host
/// writes each command with a trailing newline — so the cure is a name that
/// survives the shell and the file untouched.
///
/// Resolving here does both jobs: a name maps to its `XCUIKeyboardKey` before
/// XCTest is called, and an unrecognised multi-character token becomes an
/// ordinary error result instead of a fatal one.
///
/// The name is only half of it. `typeKey` turns out to be INERT for a key with
/// no character on the simulator, so a spelling alone would have bought a
/// politer no-op: measured on iPadOS 26.5 against the global search field,
/// `typeKey(XCUIKeyboardKey.return)` and `typeKey("\r")` both report success
/// and leave the field focused and unsubmitted, while `typeKey("a")` through
/// the same call lands a character. `typeText` with the key's own raw value
/// submits, which is why the verb sends a named key that way — see the
/// `case "key"` dispatch in `SimDriveTests`.
enum KeyStroke: Equatable {

    /// A literal one-character keystroke, e.g. `key v cmd`.
    case character(String)

    /// A named key, e.g. `key return`.
    case named(XCUIKeyboardKey)

    /// Whether XCTest has to be handed a focused app before this stroke can be
    /// delivered.
    ///
    /// The split is the delivery mechanism, not the key. A `.character` goes
    /// out through `typeKey`, which tolerates an app with nothing focused; a
    /// `.named` has no working `typeKey` form (see above) and goes out through
    /// `typeText`, which raises an XCTest *failure* — fatal to the REPL, not an
    /// error result — when no descendant has keyboard focus. So `key q` with
    /// nothing focused is a harmless no-op while `key return` cost a restart
    /// until the verb started taking the same guard `type` has taken since
    /// #902 (#1230).
    var requiresKeyboardFocus: Bool {
        switch self {
        case .character: false
        case .named: true
        }
    }
}

/// Maps a `key` token onto the keystroke XCTest should be asked for.
enum KeyStrokeTable {

    /// Canonical names, in the order the help text lists them.
    ///
    /// Deliberately not the whole of `XCUIKeyboardKey`: the F-keys, the
    /// modifier keys and `secondaryFn` are all reachable through the existing
    /// modifier words or not reachable from a simulator keyboard at all, so
    /// they would be vocabulary nobody spends. Add one when a recipe wants it.
    static let names: KeyValuePairs<String, XCUIKeyboardKey> = [
        "return": .return,
        "enter": .enter,
        "tab": .tab,
        "space": .space,
        "escape": .escape,
        "delete": .delete,
        "forwarddelete": .forwardDelete,
        "up": .upArrow,
        "down": .downArrow,
        "left": .leftArrow,
        "right": .rightArrow,
        "home": .home,
        "end": .end,
        "pageup": .pageUp,
        "pagedown": .pageDown,
        "clear": .clear,
        "help": .help
    ]

    /// The spellings a shell delivers when a recipe author writes the escape
    /// rather than the name. `key \n` and `key \e` are the two that used to
    /// kill the runner, so they resolve rather than merely erroring politely.
    static let escapeAliases: KeyValuePairs<String, XCUIKeyboardKey> = [
        #"\n"#: .return,
        #"\r"#: .return,
        #"\t"#: .tab,
        #"\e"#: .escape
    ]

    /// The keystroke `token` asks for, or nil when it is neither a single
    /// character nor a name this table knows. Nil is what the verb turns into
    /// a `DriveError`: the whole point is that an unknown token never reaches
    /// `typeKey`.
    static func stroke(for token: String) -> KeyStroke? {
        if token.count == 1 { return .character(token) }
        let lowered = token.lowercased()
        for (name, key) in names where name == lowered { return .named(key) }
        for (alias, key) in escapeAliases where alias == lowered { return .named(key) }
        return nil
    }

    /// The name list the verb quotes back when it rejects a token.
    static var helpNames: String {
        names.map(\.key).joined(separator: ", ")
    }
}
