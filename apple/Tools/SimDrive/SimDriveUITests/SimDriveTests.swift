import XCTest

/// SimDrive: a file-based command REPL for driving an installed app in
/// the simulator from outside the XCUITest process.
///
/// The host starts this "test" (which runs until told to quit) via the
/// sibling `simdrive` script, then writes numbered command files
/// (`0001.cmd`, `0002.cmd`, …) into the exchange directory. The loop
/// executes each against the target app and writes `<n>.out` with a
/// JSON result. Simulator processes can read and write host paths, so
/// the exchange directory is a plain host directory handed over via
/// the `SIMDRIVE_DIR` environment variable (the host passes it as
/// `TEST_RUNNER_SIMDRIVE_DIR` on the xcodebuild command line).
///
/// Command grammar (one command per file; `<query>` is `id:<identifier>`,
/// `text:<label>`, or `xy:<x>,<y>`). A query runs to the end of the line
/// apart from the trailing `name:value` options its verb accepts, so labels
/// with spaces — `tap text:Save Draft` — need no quoting:
///
///   launch                     launch the target app (fresh process)
///   activate                   foreground the target app (no relaunch)
///   env KEY=VALUE ...          set launch environment for the NEXT launch
///   dump                       full accessibility-tree debug description
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

    func testDriveLoop() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        if let bundleId = env["SIMDRIVE_APP"], !bundleId.isEmpty {
            targetBundleId = bundleId
        }
        let dir = URL(
            fileURLWithPath: env["SIMDRIVE_DIR"] ?? "/tmp/simdrive",
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

    private func execute(_ line: String, quit: inout Bool) throws -> String {
        let (verb, remainder) = splitVerb(line)
        let args = remainder.split(separator: " ").map(String.init)
        if Self.appDependentVerbs.contains(verb) {
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
        case "focus":
            return focusedElement()?.debugDescription ?? "none"
        case "tap":
            let query = try selector(from: remainder, verb: "tap")
            if query.hasPrefix("xy:") {
                try coordinate(from: query).tap()
            } else {
                try element(for: query).tap()
            }
            return "tapped \(query)"
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
        case "wait":
            let query = try selector(from: remainder, verb: "wait", options: ["timeout"])
            let timeout = value(named: "timeout", in: args).flatMap(Double.init) ?? 10
            let appeared = try element(for: query, requireExistence: false)
                .waitForExistence(timeout: timeout)
            return "exists=\(appeared)"
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

    private func element(for query: String, requireExistence: Bool = true) throws -> XCUIElement {
        let target: XCUIElement
        if query.hasPrefix("id:") {
            target = targetApp().descendants(matching: .any)
                .matching(identifier: String(query.dropFirst(3)))
                .firstMatch
        } else if query.hasPrefix("text:") {
            target = targetApp().descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", String(query.dropFirst(5))))
                .firstMatch
        } else {
            throw DriveError("query must be id:<identifier>, text:<label>, or xy:<x>,<y>")
        }
        if requireExistence, !target.exists {
            throw DriveError("no element for '\(query)'")
        }
        return target
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
