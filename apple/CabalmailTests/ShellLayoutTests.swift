import XCTest
@testable import CabalmailUI

/// Pins the one layout signal a window publishes (`ShellLayout`) and what the
/// layout readers make of it. Every platform's answer is asked for here, on
/// the Mac host, through the platform argument: the iOS and visionOS
/// suites never see their own shells otherwise (visionOS is build-only on a
/// PR).
final class ShellLayoutTests: XCTestCase {

    // MARK: - resolve

    func testTheMacIsAlwaysTheDesktop() {
        for (width, height) in [(true, true), (true, false), (false, true), (false, false)] {
            XCTAssertEqual(
                ShellLayout.resolve(on: .macOS, isCompactWidth: width, isCompactHeight: height, measuredWidth: 320),
                .desktop
            )
        }
    }

    func testVisionOSIsAlwaysTheOrnament() {
        for (width, height) in [(true, true), (true, false), (false, true), (false, false)] {
            XCTAssertEqual(
                ShellLayout.resolve(on: .visionOS, isCompactWidth: width, isCompactHeight: height, measuredWidth: nil),
                .ornament
            )
        }
    }

    /// iOS takes `SectionLayoutPolicy`'s answer: regular in both dimensions
    /// (an iPad, iPhone Duo's inner display) is the split; compact in either
    /// (an iPhone in any orientation, a Plus / Max in landscape, Duo's outer
    /// display, a narrow iPad window) is the tabs.
    func testIOSFollowsTheSectionLayoutPolicy() {
        XCTAssertEqual(
            ShellLayout.resolve(on: .iOS, isCompactWidth: false, isCompactHeight: false, measuredWidth: 1194),
            .split
        )
        XCTAssertEqual(
            ShellLayout.resolve(on: .iOS, isCompactWidth: true, isCompactHeight: false, measuredWidth: 402),
            .tabs
        )
        XCTAssertEqual(
            ShellLayout.resolve(on: .iOS, isCompactWidth: false, isCompactHeight: true, measuredWidth: 956),
            .tabs,
            "a Plus / Max in landscape keeps the tabs"
        )
    }

    /// The width floor rides through: a regular-width trait over a window
    /// still laid out narrow (an unfolding Duo, #1679) holds the tabs for that
    /// pass.
    func testIOSHoldsTheTabsBelowTheWidthFloor() {
        XCTAssertEqual(
            ShellLayout.resolve(on: .iOS, isCompactWidth: false, isCompactHeight: false, measuredWidth: 466),
            .tabs
        )
        XCTAssertEqual(
            ShellLayout.resolve(on: .iOS, isCompactWidth: false, isCompactHeight: false, measuredWidth: nil),
            .split,
            "no measurement yet trusts the size classes"
        )
    }

    func testTheWatchHasNoSplit() {
        XCTAssertEqual(
            ShellLayout.resolve(on: .watchOS, isCompactWidth: false, isCompactHeight: false, measuredWidth: nil),
            .tabs
        )
    }

    /// Outside a main window's root a view reads the platform's own shell;
    /// on this host, the desktop.
    func testTheStandaloneLayoutIsThisPlatformsShell() {
        XCTAssertEqual(ShellLayout.standalone, .desktop)
    }

    // MARK: - The navigator's wide flag

    /// The navigator's `layoutIsWide`: the desktop and the split tile a list
    /// beside a reader with the sidebar; the tab layouts don't.
    func testOnlyTheDesktopAndTheSplitAreWideSplits() {
        XCTAssertTrue(ShellLayout.desktop.isWideSplit)
        XCTAssertTrue(ShellLayout.split.isWideSplit)
        XCTAssertFalse(ShellLayout.tabs.isWideSplit)
        XCTAssertFalse(ShellLayout.ornament.isWideSplit)
    }

    // MARK: - Platform capabilities

    func testOnlyIPadOSScopesItsBarToTheColumn() {
        XCTAssertTrue(HostPlatform.iOS.columnScopedToolbar)
        XCTAssertFalse(HostPlatform.macOS.columnScopedToolbar)
        XCTAssertFalse(HostPlatform.visionOS.columnScopedToolbar)
        XCTAssertFalse(HostPlatform.watchOS.columnScopedToolbar)
    }

    func testOnlyVisionOSDrawsOverPassthrough() {
        XCTAssertTrue(HostPlatform.visionOS.drawsOverPassthrough)
        XCTAssertFalse(HostPlatform.macOS.drawsOverPassthrough)
        XCTAssertFalse(HostPlatform.iOS.drawsOverPassthrough)
        XCTAssertFalse(HostPlatform.watchOS.drawsOverPassthrough)
    }

    /// The Mac and visionOS never present the compose sheet, so a new message
    /// there is always a window; iOS asks its scene
    /// (`ComposeSurfacePolicy.opensInWindow`).
    func testOnlyTheMacAndVisionOSAlwaysComposeInAWindow() {
        XCTAssertTrue(HostPlatform.macOS.alwaysWindows)
        XCTAssertTrue(HostPlatform.visionOS.alwaysWindows)
        XCTAssertFalse(HostPlatform.iOS.alwaysWindows)
        XCTAssertFalse(HostPlatform.watchOS.alwaysWindows)
    }

    // MARK: - What the layout readers make of it

    /// The split's column-scoped bar can't seat the folder or scope switch
    /// (#1626), so it moves into the column there. The iPad list column
    /// reports a compact size class, which is why the readers ask the shell.
    func testTheTitleSwitchMovesIntoTheColumnOnlyOnTheIPadSplit() {
        XCTAssertEqual(FolderSwitchPlacement.host(in: .split, on: .iOS), .columnHeader)
        XCTAssertEqual(FolderSwitchPlacement.host(in: .tabs, on: .iOS), .titleMenu)
        XCTAssertEqual(FolderSwitchPlacement.host(in: .ornament, on: .visionOS), .titleMenu)
        XCTAssertEqual(FolderSwitchPlacement.host(in: .desktop, on: .macOS), .titleMenu)
    }

    func testTheSearchFieldFollowsTheShell() {
        XCTAssertEqual(GlobalSearchFieldPlacement.host(in: .desktop, on: .macOS), .toolbar)
        XCTAssertEqual(GlobalSearchFieldPlacement.host(in: .split, on: .iOS), .columnHeader)
        XCTAssertEqual(GlobalSearchFieldPlacement.host(in: .tabs, on: .iOS), .none)
        XCTAssertEqual(GlobalSearchFieldPlacement.host(in: .ornament, on: .visionOS), .none)
    }

    /// Only the tabs draw a bar across the bottom band — a Plus / Max in
    /// landscape included, though its width is regular.
    func testOnlyTheTabsLiftTheBanners() {
        XCTAssertEqual(StatusBannerPlacement.bottomInset(in: .tabs), StatusBannerPlacement.compactWidthBottomInset)
        for layout in [ShellLayout.desktop, .split, .ornament] {
            XCTAssertEqual(StatusBannerPlacement.bottomInset(in: layout), StatusBannerPlacement.defaultBottomInset)
        }
    }
}
