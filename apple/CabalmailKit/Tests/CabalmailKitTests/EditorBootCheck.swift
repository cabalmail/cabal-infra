import XCTest
@testable import CabalmailKit

/// The check a live-editor test's `setUp` makes once the page should have
/// loaded. On visionOS a bridge that never booted skips the test: the
/// visionOS simulator's WebKit sometimes never finishes loading the editor
/// page (#2252), which says nothing about the editor and turned stage runs
/// red at random. Everywhere else it fails the test, as it always did.
@MainActor
func requireEditorBooted(
    _ controller: RichTextEditorController,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    #if os(visionOS)
    if controller.bridgeFailure != nil {
        throw XCTSkip("The visionOS simulator's WebKit never finished loading the editor page (#2252).")
    }
    #endif
    XCTAssertNil(controller.bridgeFailure, "editor bridge never booted in this runner", file: file, line: line)
}
