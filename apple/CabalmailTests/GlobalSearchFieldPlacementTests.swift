import XCTest
@testable import Cabalmail

/// The #1047 rework put the global search field in the message-list column's
/// toolbar on every wide layout. On iPadOS that column draws its own UIKit
/// navigation bar at column width — 360pt by default, already carrying four
/// fixed buttons — so the field overran the section and UIKit folded it, and
/// the Addresses button beside it, into a system overflow that never presents:
/// both controls were unreachable (#1052/#1058). iPadOS therefore hosts the
/// field in the column's content instead.
final class GlobalSearchFieldPlacementTests: XCTestCase {
    /// The defect, as a test: a column-scoped bar does not host the field.
    func testAColumnScopedBarDoesNotHostTheField() {
        XCTAssertEqual(
            GlobalSearchFieldPlacement.host(isWideSidebar: true, columnScopedToolbar: true),
            .columnHeader
        )
    }

    /// Width is deliberately not an input. The list column is a drag handle
    /// away from any width in its range, and a host that switched partway
    /// through the drag would move the search field out from under the
    /// pointer — so the decision is layout-only, and this asserts the whole
    /// truth table rather than sweeping a dimension the policy doesn't read.
    func testThePlacementIsAFunctionOfLayoutAlone() {
        XCTAssertEqual(
            GlobalSearchFieldPlacement.host(isWideSidebar: true, columnScopedToolbar: true),
            .columnHeader
        )
        XCTAssertEqual(
            GlobalSearchFieldPlacement.host(isWideSidebar: true, columnScopedToolbar: false),
            .toolbar
        )
        XCTAssertEqual(
            GlobalSearchFieldPlacement.host(isWideSidebar: false, columnScopedToolbar: true),
            .none
        )
        XCTAssertEqual(
            GlobalSearchFieldPlacement.host(isWideSidebar: false, columnScopedToolbar: false),
            .none
        )
    }

    /// macOS and visionOS share a window-wide bar with room for the field and
    /// keep it there — the column-hosted field is an iPadOS remedy, not a
    /// redesign of the layout that was measured working (#1055, #1057).
    func testAWindowWideBarKeepsHostingTheField() {
        XCTAssertEqual(
            GlobalSearchFieldPlacement.host(isWideSidebar: true, columnScopedToolbar: false),
            .toolbar
        )
    }

    /// The compile-time half of the policy: iPadOS is the column-scoped
    /// platform, macOS is not. Asserted so a platform added to the wrong arm
    /// of the `#if` fails a test rather than shipping an unreachable search
    /// field.
    func testThePlatformFlagMatchesTheRunningPlatform() {
        #if os(iOS)
        XCTAssertTrue(GlobalSearchFieldPlacement.platformColumnScopedToolbar)
        #else
        XCTAssertFalse(GlobalSearchFieldPlacement.platformColumnScopedToolbar)
        #endif
    }
}
