import XCTest

/// SimDrive: a file-based command REPL for driving an installed app in
/// the simulator from outside the XCUITest process.
///
/// The host starts this "test" (which runs until told to quit) via the
/// sibling `simdrive` script, then writes numbered command files
/// (`0001.cmd`, `0002.cmd`, …) into the exchange directory. The loop
/// executes each against the target app and writes `<n>.out` with a
/// JSON result. A simulator process (i.e. iOS and visionOS alike) can read
/// and write host paths, so the exchange directory is a plain host
/// directory handed over via the `SIMDRIVE_DIR` environment variable
/// (the host passes it as `TEST_RUNNER_SIMDRIVE_DIR` on the xcodebuild
/// command line). visionOS drops that `TEST_RUNNER_*` injection (#872),
/// so when the environment is empty the settings are read from the
/// fixed rendezvous file the host also writes, at
/// `/tmp/simdrive/config.json`.
///
/// Command grammar (one command per file; `<query>` is `id:<identifier>`,
/// `text:<label>`, or `xy:<x>,<y>`, and `sysid:`/`systext:` for the
/// system-UI variants — see `systemAppCandidates`). A query runs to the
/// end of the line apart from the trailing `name:value` options its verb
/// accepts, so labels with spaces — `tap text:Save Draft` — need no
/// quoting:
///
///   launch                     launch the target app (fresh process)
///   activate                   foreground the target app (no relaunch)
///   env KEY=VALUE ...          set launch environment for the NEXT launch
///   dump                       full accessibility-tree debug description
///   sysdump [<bundleid>]       the same for the system-UI process: a
///                              per-candidate summary line, then the tree
///                              of the first one holding any UI
///   sysapp [<bundleid>|auto]   pin the system-UI process `sys` queries
///                              resolve against (default: auto-probe)
///   focus                      description of the keyboard-focused element
///   tap <query>                tap an element (or coordinate)
///   type <text>                type into the focused element (rest of line,
///                              verbatim — but see `cmdv` for secrets)
///   cmdv                       hardware Cmd-V paste (seed the pasteboard
///                              host-side with `simctl pbcopy`; the ONLY
///                              way into a SecureField, and keeps secrets
///                              out of command files and logs)
///   key <char> [mods...]       one hardware keystroke with modifiers
///                              (cmd, shift, alt, ctrl), e.g.
///                              `key v cmd shift` for Cmd-Shift-V
///   orient portrait|left|right|upsidedown
///   drag from:<x>,<y> to:<x>,<y> [press:<s>] [hold:<s>]
///                              press, drag, then HOLD before release —
///                              gestures occupy this process's main
///                              thread, so observe the held state from
///                              the host (simctl screenshot) during hold
///   swiperow <query> edge:leading|trailing [hold:<s>]
///                              horizontal swipe within an element to
///                              reveal its swipe actions
///   exists <query>             "exists=<bool> hittable=<bool>"
///   wait <query> [timeout:<s>] wait for existence (default 10s)
///   quit                       end the loop (the test finishes)
final class SimDriveTests: XCTestCase {

    private struct DriveError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private var app: XCUIApplication?
    private var pendingLaunchEnvironment: [String: String] = [:]
    private var targetBundleId = "com.cabalmail.Cabalmail"

    /// System-owned UI — permission alerts, AutoFill sheets, edit menus —
    /// lives outside the target app's hierarchy, so nothing scoped to the
    /// target app can see it, let alone answer it (#1025). `sys` queries
    /// resolve against the platform's system-UI process instead.
    ///
    /// Which process that is differs by platform, so it is probed rather
    /// than hard-coded: the visionOS runtime ships no `SpringBoard.app` at
    /// all (its shell is split across the `com.apple.Reality*` processes),
    /// and a query scoped to a bundle id that does not exist reports every
    /// element as absent — indistinguishable from a broken verb. `sysapp`
    /// pins one explicitly when the host is known or not on this list.
    private static let systemAppCandidates = [
        "com.apple.springboard",           // iOS, iPadOS
        "com.apple.RealityNotifications",  // visionOS: notifications, alerts
        "com.apple.RealityChrome",         // visionOS: window chrome, sheets
        "com.apple.RealityKeyboard",       // visionOS: the system keyboard
        "com.apple.RealityCoverSheet",
        "com.apple.RealityLauncher",
        "com.apple.RealityHUD"
    ]

    /// Set by `sysapp`; when nil every candidate is probed in order.
    private var pinnedSystemBundleId: String?
    /// The candidate that last answered a `sys` query — reported back so a
    /// session learns which process owns the UI it just drove, and tried
    /// first on the next one.
    private var resolvedSystemBundleId: String?

    func testDriveLoop() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        var dirPath = env["SIMDRIVE_DIR"]
        var bundleId = env["SIMDRIVE_APP"]
        // Environment first (works on iOS); the rendezvous file covers
        // visionOS, where TEST_RUNNER_* injection never arrives.
        if dirPath == nil || bundleId == nil,
           let data = FileManager.default.contents(atPath: "/tmp/simdrive/config.json"),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dirPath = dirPath ?? config["dir"]
            bundleId = bundleId ?? config["app"]
        }
        if let bundleId, !bundleId.isEmpty {
            targetBundleId = bundleId
        }
        let dir = URL(
            fileURLWithPath: dirPath ?? "/tmp/simdrive",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Host-visible readiness marker: the driver polls for this before
        // accepting commands, so `simdrive start` blocks until the runner
        // is actually listening.
        try "ready\n".write(
            to: dir.appendingPathComponent("runner.ready"),
            atomically: true,
            encoding: .utf8
        )

        while true {
            guard let cmdURL = nextCommand(in: dir) else {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let line = ((try? String(contentsOf: cmdURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var quit = false
            var payload: [String: Any]
            do {
                payload = ["ok": true, "value": try execute(line, quit: &quit)]
            } catch {
                payload = ["ok": false, "error": error.localizedDescription]
            }
            writeResult(payload, for: cmdURL)
            // Rename after the result exists so the host's "poll for
            // <n>.out" protocol never races the done-marker.
            try? FileManager.default.moveItem(
                at: cmdURL,
                to: cmdURL.appendingPathExtension("done")
            )
            if quit { break }
        }
    }

    // MARK: - Command dispatch

    /// Verbs that reach into the target app's accessibility tree. Every one
    /// of them raises an XCTest *failure* (not a Swift error) when the app
    /// isn't running, and that failure unwinds `testDriveLoop` — killing the
    /// REPL rather than answering the command (#902). Checking the app's
    /// state first turns that into an ordinary error result.
    private static let appDependentVerbs: Set<String> = [
        "dump", "focus", "tap", "type", "cmdv", "key", "drag", "swiperow", "exists", "wait"
    ]

    /// Verbs whose argument begins with a query, and which therefore may be
    /// `sys`-scoped. Kept separate from a bare `remainder.hasPrefix("sys")`
    /// test, which would also match the free text of `type system…`.
    private static let queryingVerbs: Set<String> = ["tap", "exists", "wait", "swiperow"]

    private func execute(_ line: String, quit: inout Bool) throws -> String {
        let (verb, remainder) = splitVerb(line)
        let args = remainder.split(separator: " ").map(String.init)
        // A `sys` query reaches UI the target app does not own — the alert
        // blocking a first launch is exactly the case — so it must work
        // whether or not the app is running.
        let systemScoped = Self.queryingVerbs.contains(verb) && remainder.hasPrefix("sys")
        if Self.appDependentVerbs.contains(verb), !systemScoped {
            try requireRunningApp()
        }
        switch verb {
        case "quit":
            quit = true
            return "bye"
        case "launch":
            let fresh = XCUIApplication(bundleIdentifier: targetBundleId)
            fresh.launchEnvironment = pendingLaunchEnvironment
            fresh.launch()
            app = fresh
            return "launched \(targetBundleId)"
        case "activate":
            targetApp().activate()
            return "activated"
        case "env":
            for pair in args {
                guard let eq = pair.firstIndex(of: "=") else {
                    throw DriveError("env expects KEY=VALUE, got '\(pair)'")
                }
                pendingLaunchEnvironment[String(pair[..<eq])] =
                    String(pair[pair.index(after: eq)...])
            }
            return "env set for next launch (\(pendingLaunchEnvironment.count) keys)"
        case "dump":
            return targetApp().debugDescription
        case "sysdump":
            return systemDump(args.first)
        case "sysapp":
            return systemApp(args.first)
        case "focus":
            return focusedElement()?.debugDescription ?? "none"
        case "tap":
            let query = try selector(from: remainder, verb: "tap")
            if query.hasPrefix("xy:") {
                try coordinate(from: query).tap()
            } else {
                try element(for: query).tap()
            }
            return "tapped \(query)\(hostNote(for: query))"
        case "type":
            // `typeText` with nothing focused raises an XCTest failure, which
            // takes the whole loop down with it (#902) — refuse first.
            guard focusedElement() != nil else {
                throw DriveError("no keyboard focus — tap a text field before typing")
            }
            targetApp().typeText(remainder)
            return "typed \(remainder.count) characters"
        case "cmdv":
            targetApp().typeKey("v", modifierFlags: .command)
            return "pasted"
        case "key":
            guard let keyChar = args.first else {
                throw DriveError("key expects: key <char> [cmd|shift|alt|ctrl ...]")
            }
            var flags: XCUIElement.KeyModifierFlags = []
            for mod in args.dropFirst() {
                switch mod {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "alt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: throw DriveError("unknown modifier '\(mod)'")
                }
            }
            targetApp().typeKey(keyChar, modifierFlags: flags)
            return "keyed \(([keyChar] + args.dropFirst()).joined(separator: "+"))"
        case "orient":
            try orient(args.first ?? "")
            return "oriented \(args.first ?? "")"
        case "drag":
            return try drag(args)
        case "swiperow":
            return try swipeRow(remainder)
        case "exists":
            let query = try selector(from: remainder, verb: "exists")
            let target = try element(for: query, requireExistence: false)
            let exists = target.exists
            return "exists=\(exists) hittable=\(exists ? target.isHittable : false)"
                + (exists ? hostNote(for: query) : "")
        case "wait":
            let query = try selector(from: remainder, verb: "wait", options: ["timeout"])
            let timeout = value(named: "timeout", in: args).flatMap(Double.init) ?? 10
            let appeared = query.hasPrefix("sys")
                ? try waitForSystemElement(query, timeout: timeout)
                : try element(for: query, requireExistence: false)
                    .waitForExistence(timeout: timeout)
            return "exists=\(appeared)\(appeared ? hostNote(for: query) : "")"
        default:
            throw DriveError("unknown verb '\(verb)'")
        }
    }

    // MARK: - Gestures

    private func drag(_ args: [String]) throws -> String {
        guard let from = value(named: "from", in: args),
              let to = value(named: "to", in: args) else {
            throw DriveError("drag expects from:<x>,<y> to:<x>,<y>")
        }
        let press = value(named: "press", in: args).flatMap(Double.init) ?? 0.2
        let hold = value(named: "hold", in: args).flatMap(Double.init) ?? 0
        try coordinate(from: "xy:\(from)").press(
            forDuration: press,
            thenDragTo: try coordinate(from: "xy:\(to)"),
            withVelocity: .default,
            thenHoldForDuration: hold
        )
        return "dragged \(from) -> \(to) (press \(press)s, hold \(hold)s)"
    }

    private func swipeRow(_ remainder: String) throws -> String {
        let query = try selector(from: remainder, verb: "swiperow", options: ["edge", "hold"])
        let args = remainder.split(separator: " ").map(String.init)
        let edge = value(named: "edge", in: args) ?? "trailing"
        let hold = value(named: "hold", in: args).flatMap(Double.init) ?? 0.5
        let row = try element(for: query)
        // Partial-width drag: a sweep across most of the row registers as
        // a full swipe — EXECUTING the action rather than revealing the
        // buttons. The execute threshold sits near the row's midpoint, so
        // park the reveal with a drag of roughly a third of the row width.
        let (fromX, toX): (CGFloat, CGFloat) = edge == "leading" ? (0.15, 0.42) : (0.88, 0.45)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.5))
        start.press(
            forDuration: 0.15,
            thenDragTo: end,
            withVelocity: .default,
            thenHoldForDuration: hold
        )
        return "swiped \(query) \(edge) (hold \(hold)s)"
    }

    private func orient(_ name: String) throws {
        switch name {
        case "portrait":   XCUIDevice.shared.orientation = .portrait
        case "left":       XCUIDevice.shared.orientation = .landscapeLeft
        case "right":      XCUIDevice.shared.orientation = .landscapeRight
        case "upsidedown": XCUIDevice.shared.orientation = .portraitUpsideDown
        default:
            throw DriveError("orient expects portrait|left|right|upsidedown")
        }
    }

    // MARK: - Query resolution

    private func targetApp() -> XCUIApplication {
        if let app { return app }
        let attached = XCUIApplication(bundleIdentifier: targetBundleId)
        app = attached
        return attached
    }

    /// Throws rather than letting a query run against an app that isn't
    /// there — see `appDependentVerbs`.
    private func requireRunningApp() throws {
        let state = targetApp().state
        guard state != .notRunning, state != .unknown else {
            throw DriveError(
                "target app \(targetBundleId) is not running — 'launch' it first"
            )
        }
    }

    private func focusedElement() -> XCUIElement? {
        let focused = targetApp().descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .firstMatch
        return focused.exists ? focused : nil
    }

    /// The selector argument of a verb that takes one, which is everything
    /// before the trailing run of `name:value` option tokens.
    ///
    /// Splitting on spaces and taking the first token truncated every
    /// multi-word label — `tap text:Search all mail` silently tapped the
    /// tab-bar `Search` button instead (#902), and since `element(for:)`
    /// matches labels exactly, no multi-word label was addressable at all.
    /// Options only ever follow the selector, so scanning in from the end
    /// for the ones this verb accepts is unambiguous and leaves the spaces
    /// in the label alone.
    private func selector(
        from remainder: String,
        verb: String,
        options: Set<String> = []
    ) throws -> String {
        var tokens = remainder.split(separator: " ").map(String.init)
        while let last = tokens.last,
              let colon = last.firstIndex(of: ":"),
              options.contains(String(last[..<colon])) {
            tokens.removeLast()
        }
        let query = tokens.joined(separator: " ")
        guard !query.isEmpty else { throw DriveError("\(verb) expects a query") }
        return query
    }

    /// A parsed query: what to match on, and whether to look in the target
    /// app or in the system-UI process (`sysid:` / `systext:`).
    private struct ParsedQuery {
        enum Kind { case identifier, label }
        let kind: Kind
        let value: String
        let isSystem: Bool

        init?(_ raw: String) {
            var rest = raw
            isSystem = rest.hasPrefix("sys")
            if isSystem { rest = String(rest.dropFirst(3)) }
            if rest.hasPrefix("id:") {
                kind = .identifier
                value = String(rest.dropFirst(3))
            } else if rest.hasPrefix("text:") {
                kind = .label
                value = String(rest.dropFirst(5))
            } else {
                return nil
            }
        }
    }

    private func element(for query: String, requireExistence: Bool = true) throws -> XCUIElement {
        guard let parsed = ParsedQuery(query) else {
            throw DriveError(
                "query must be id:<identifier>, text:<label>, xy:<x>,<y>, "
                + "or the system-UI forms sysid:/systext:"
            )
        }
        if parsed.isSystem {
            return try systemElement(for: parsed, query: query, requireExistence: requireExistence)
        }
        let target = match(parsed, in: targetApp())
        if requireExistence, !target.exists {
            throw DriveError("no element for '\(query)'")
        }
        return target
    }

    private func match(_ parsed: ParsedQuery, in root: XCUIApplication) -> XCUIElement {
        switch parsed.kind {
        case .identifier:
            return root.descendants(matching: .any)
                .matching(identifier: parsed.value)
                .firstMatch
        case .label:
            return root.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", parsed.value))
                .firstMatch
        }
    }

    // MARK: - System UI

    /// Candidate hosts in probe order: whichever answered last (or was
    /// pinned by `sysapp`) first, then the platform defaults.
    private func systemBundleIds() -> [String] {
        if let pinnedSystemBundleId { return [pinnedSystemBundleId] }
        guard let resolvedSystemBundleId else { return Self.systemAppCandidates }
        return [resolvedSystemBundleId]
            + Self.systemAppCandidates.filter { $0 != resolvedSystemBundleId }
    }

    private func systemElement(
        for parsed: ParsedQuery,
        query: String,
        requireExistence: Bool
    ) throws -> XCUIElement {
        let candidates = systemBundleIds()
        // Cleared up front so the host reported back always describes THIS
        // probe rather than an earlier one that happened to succeed.
        resolvedSystemBundleId = nil
        var firstMiss: XCUIElement?
        for bundleId in candidates {
            let candidate = match(parsed, in: XCUIApplication(bundleIdentifier: bundleId))
            if candidate.exists {
                resolvedSystemBundleId = bundleId
                return candidate
            }
            firstMiss = firstMiss ?? candidate
        }
        guard let firstMiss, !requireExistence else {
            throw DriveError(
                "no system element for '\(query)' "
                + "(searched \(candidates.joined(separator: ", ")))"
            )
        }
        return firstMiss
    }

    /// `waitForExistence` binds to one process's element, so a system wait
    /// re-probes instead: the process hosting an alert may not even be
    /// running when the wait starts.
    private func waitForSystemElement(_ query: String, timeout: Double) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try element(for: query, requireExistence: false).exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// Reports which system process answered, so a session that does not
    /// know the platform's host — the visionOS case — learns it from the
    /// first command that works.
    private func hostNote(for query: String) -> String {
        guard query.hasPrefix("sys"), let resolvedSystemBundleId else { return "" }
        return " in \(resolvedSystemBundleId)"
    }

    /// One summary line per candidate, then the tree of the first one
    /// holding any UI — enough to answer "which process owns this alert?"
    /// in a single command without dumping six hierarchies.
    private func systemDump(_ bundleId: String?) -> String {
        let candidates = bundleId.map { [$0] } ?? systemBundleIds()
        var summary: [String] = []
        var tree: String?
        for id in candidates {
            let app = XCUIApplication(bundleIdentifier: id)
            let populated = app.descendants(matching: .any).firstMatch.exists
            summary.append("\(id): state=\(app.state.rawValue) elements=\(populated ? "yes" : "none")")
            if tree == nil, populated || candidates.count == 1 {
                resolvedSystemBundleId = id
                tree = "\n=== \(id) ===\n\(app.debugDescription)"
            }
        }
        return summary.joined(separator: "\n") + (tree ?? "\n(no candidate reported any UI)")
    }

    private func systemApp(_ bundleId: String?) -> String {
        switch bundleId {
        case .none:
            return "system app: \(pinnedSystemBundleId ?? "auto")"
                + " (last resolved: \(resolvedSystemBundleId ?? "none"))"
        case "auto":
            pinnedSystemBundleId = nil
            return "system app: auto (\(Self.systemAppCandidates.count) candidates)"
        case let .some(id):
            pinnedSystemBundleId = id
            resolvedSystemBundleId = nil
            return "system app pinned to \(id)"
        }
    }

    private func coordinate(from query: String) throws -> XCUICoordinate {
        let parts = query.dropFirst(3).split(separator: ",")
        guard parts.count == 2,
              let xOffset = Double(parts[0]), let yOffset = Double(parts[1]) else {
            throw DriveError("coordinate must be xy:<x>,<y>")
        }
        return targetApp()
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: xOffset, dy: yOffset))
    }

    // MARK: - Plumbing

    private func splitVerb(_ line: String) -> (verb: String, remainder: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (
            String(line[..<space]),
            String(line[line.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
        )
    }

    /// Extracts `<name>:<value>` from an argument list.
    private func value(named name: String, in args: [String]) -> String? {
        for arg in args where arg.hasPrefix("\(name):") {
            return String(arg.dropFirst(name.count + 1))
        }
        return nil
    }

    private func nextCommand(in dir: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "cmd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func writeResult(_ payload: [String: Any], for cmdURL: URL) {
        let outURL = cmdURL.deletingPathExtension().appendingPathExtension("out")
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{\"ok\": false, \"error\": \"result serialization failed\"}".utf8)
        // Write-then-rename so the host never reads a half-written result.
        let tmpURL = outURL.appendingPathExtension("tmp")
        try? data.write(to: tmpURL)
        try? FileManager.default.moveItem(at: tmpURL, to: outURL)
    }
}
