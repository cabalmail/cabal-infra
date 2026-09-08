import XCTest
import SwiftUI
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1460.
//
// The main window and the macOS Settings scene each pinned the Theme
// preference with their own private copy of the same three-case mapping.
// The compose scene — a third `WindowGroup`, installed by both app targets
// — had no copy and asked nothing, so on iPadOS (and by construction macOS
// and visionOS, which open compose the same way) the composer drew in the
// system appearance while the app around it drew in the user's Theme.
//
// A scene is its own appearance root, so the rule can only ever be "every
// scene pins it". `AppearancePolicyTests` proves the mapping is right; this
// suite proves no scene is left answering the question by itself. Deleting
// `.themedAppearance` from ComposeWindowScene.swift fails
// `testEverySceneRootPinsTheTheme` by name.
final class SceneAppearanceSourceScanTests: XCTestCase {

    /// Scene roots that legitimately draw without the app's Theme, by path
    /// under `apple/`, with a count.
    ///
    /// `MenuBarExtra`'s `.menu` style hands its items to the system menu
    /// bar, which draws them in the menu bar's own appearance — there is no
    /// window whose scheme we could pin, and pinning one would leave a menu
    /// disagreeing with every other menu on the bar.
    ///
    /// `CabalmailWatch` is outside the scan entirely: the target has no
    /// `Preferences` at all (`grep -i theme apple/CabalmailWatch` is empty
    /// — it carries `WatchAppModel`, not the preference store), so there is
    /// no theme to pin. If the watch ever gains the preference it needs the
    /// rule and this scan needs the target; the two go together.
    private static let unthemedScenes = ["CabalmailMac/CabalmailMacApp.swift": 1]

    /// Every scene the app targets declare either pins the theme or is
    /// listed above.
    func testEverySceneRootPinsTheTheme() throws {
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

        var sceneFiles: [String: Int] = [:]
        var unpinned: [String: Int] = [:]
        for (name, body) in sources {
            let scenes = try Self.sceneRoots(in: body)
            guard scenes > 0 else { continue }
            sceneFiles[name] = scenes
            let shortfall = scenes - (try Self.themePins(in: body))
            if shortfall > 0 { unpinned[name] = shortfall }
        }

        // The three files that declare scenes today. A new one appearing
        // here is not a failure; a new one appearing *unpinned* is.
        XCTAssertEqual(
            sceneFiles,
            [
                "Cabalmail/CabalmailApp.swift": 1,
                "Cabalmail/Views/ComposeWindowScene.swift": 1,
                "CabalmailMac/CabalmailMacApp.swift": 3,
            ],
            "scene inventory moved — check the new scene pins the theme (#1460)"
        )
        XCTAssertEqual(
            unpinned, Self.unthemedScenes,
            "a scene is its own appearance root: pin it with .themedAppearance (#1460)"
        )
    }

    /// Only the policy may spell the SwiftUI modifier. This is what stops a
    /// fourth private copy of the mapping — the shape that produced #1460 in
    /// the first place, two copies of a one-line rule and a scene that had
    /// neither.
    func testOnlyThePolicySpellsPreferredColorScheme() throws {
        var offenders: [String] = []
        for (name, body) in try Self.appSources()
        where try Self.rawModifierHits(in: body) > 0 {
            offenders.append(name)
        }
        XCTAssertEqual(
            offenders.sorted(), ["Cabalmail/Views/AppearancePolicy.swift"],
            "ask .themedAppearance(_:) rather than mapping the theme again (#1460)"
        )
    }

    /// Proves each detector catches the reported shape, on synthetic
    /// snippets rather than on the corpus — so a legitimate rewrite of the
    /// app entry points cannot quietly make the scan above vacuous.
    func testDetectorsCatchTheReportedShapes() throws {
        XCTAssertEqual(try Self.sceneRoots(in: "        WindowGroup {"), 1)
        XCTAssertEqual(
            try Self.sceneRoots(in: #"WindowGroup("New Message", id: composeWindowID, for: S.self) {"#),
            1
        )
        XCTAssertEqual(try Self.sceneRoots(in: "        Settings {"), 1)
        XCTAssertEqual(try Self.sceneRoots(in: "        MenuBarExtra("), 1)
        // A type whose name merely starts with a scene's is not a scene.
        XCTAssertEqual(try Self.sceneRoots(in: "SettingsTabsView()"), 0)
        XCTAssertEqual(try Self.sceneRoots(in: "WindowGroupPolicy()"), 0)
        // Prose about a scene is not a scene: three of this repo's doc
        // comments name `WindowGroup(for:)` while declaring nothing.
        XCTAssertEqual(try Self.sceneRoots(in: "/// `WindowGroup(for:)` keys each compose scene"), 0)

        XCTAssertEqual(try Self.themePins(in: ".themedAppearance(preferences.theme)"), 1)
        XCTAssertEqual(try Self.themePins(in: "// .themedAppearance(preferences.theme)"), 0)
        XCTAssertEqual(try Self.rawModifierHits(in: ".preferredColorScheme(nil)"), 1)
        XCTAssertEqual(
            try Self.rawModifierHits(in: "        preferredColorScheme(AppearancePolicy.colorScheme(for: theme))"),
            1
        )
        XCTAssertEqual(try Self.rawModifierHits(in: "/// `preferredColorScheme` does not cross scenes"), 0)
    }

    private static func sceneRoots(in body: String) throws -> Int {
        try code(body).ranges(
            of: Regex(#"\b(WindowGroup|Settings|MenuBarExtra|DocumentGroup|Window)\s*[({]"#)
        ).count
    }

    private static func themePins(in body: String) throws -> Int {
        try code(body).ranges(of: Regex(#"\.themedAppearance\("#)).count
    }

    private static func rawModifierHits(in body: String) throws -> Int {
        try code(body).ranges(of: Regex(#"\bpreferredColorScheme\("#)).count
    }

    /// Line comments cut first: a doc comment naming a scene type describes
    /// the rule, it does not declare one.
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

/// The mapping itself. Three cases, and the one that matters is `.system`:
/// a `nil` scheme is what lets the OS keep switching light/dark, so a policy
/// that returned `.light` there would break the default preference.
final class AppearancePolicyTests: XCTestCase {
    func testSystemFollowsTheOS() {
        XCTAssertNil(AppearancePolicy.colorScheme(for: .system))
    }

    func testExplicitThemesPin() {
        XCTAssertEqual(AppearancePolicy.colorScheme(for: .light), .light)
        XCTAssertEqual(AppearancePolicy.colorScheme(for: .dark), .dark)
    }

    func testEveryThemeIsMapped() {
        for theme in AppTheme.allCases {
            let scheme = AppearancePolicy.colorScheme(for: theme)
            XCTAssertEqual(scheme == nil, theme == .system, "\(theme)")
        }
    }
}
