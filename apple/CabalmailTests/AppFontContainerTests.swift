import AppKit
import SwiftUI
import XCTest
@testable import CabalmailUI

/// The interface text size where a container styles its own text: form
/// section headers and footers, sidebar rows, and native controls. At
/// `.medium` each keeps exactly what its container gives it; at any other
/// step it takes the container's style at that size.
@MainActor
final class AppFontContainerTests: XCTestCase {
    /// Stands in for a container's own font: big enough that inheriting it
    /// and taking a text style's size can't be confused.
    private static let containerFont = Font.system(size: 24)

    /// At the default size the modifier leaves the inherited font alone:
    /// the view measures exactly as it does without the modifier.
    func testMediumKeepsTheContainersFont() {
        let inherited = height(of: Text("Hg"), in: Self.containerFont, at: .medium)
        XCTAssertEqual(height(of: Text("Hg").appFontWhenScaled(.caption), in: Self.containerFont, at: .medium),
                       inherited)
        XCTAssertEqual(height(of: FormSectionHeader { Text("Hg") }, in: Self.containerFont, at: .medium), inherited)
        XCTAssertEqual(height(of: FormSectionFooter { Text("Hg") }, in: Self.containerFont, at: .medium), inherited)
    }

    /// Off the default, the modifier sets the named style at that size,
    /// whatever the container's font was.
    func testOtherStepsTakeTheStyleAtThatSize() {
        for size in [AppTextSize.xSmall, .small, .large, .xLarge] {
            XCTAssertEqual(
                height(of: Text("Hg").appFontWhenScaled(.caption), in: Self.containerFont, at: size),
                height(of: Text("Hg").font(.app(.caption, size)), in: nil, at: size),
                "\(size)"
            )
            XCTAssertEqual(
                height(of: FormSectionHeader { Text("Hg") }, in: Self.containerFont, at: size),
                height(of: Text("Hg").font(.app(.headline, size)), in: nil, at: size),
                "header at \(size)"
            )
            XCTAssertEqual(
                height(of: FormSectionFooter { Text("Hg") }, in: Self.containerFont, at: size),
                height(of: Text("Hg").font(.app(.subheadline, size)), in: nil, at: size),
                "footer at \(size)"
            )
        }
    }

    /// A header keeps the headline's bold weight off the default, which is
    /// what tells it from the rows under it.
    func testScaledHeaderIsBold() {
        let text = "Header weight check, wide enough to tell"
        XCTAssertGreaterThan(
            width(of: FormSectionHeader { Text(text) }, in: nil, at: .large),
            width(of: Text(text).font(.app(.body, .large)), in: nil, at: .large)
        )
    }

    /// The shared sidebar row takes the body style at the step, since the
    /// sidebar list ignores a font set above the row's own text; at the
    /// default it is left to the sidebar.
    func testSidebarRowTitleFollowsTheStep() {
        func row() -> some View {
            SidebarTreeRowLabel(title: "Hg", systemImage: "tray", depth: 0, disclosure: nil,
                                hasUnread: false, isSelected: false) { EmptyView() }
        }
        XCTAssertEqual(height(of: row(), in: Self.containerFont, at: .medium),
                       height(of: Text("Hg"), in: Self.containerFont, at: .medium))
        XCTAssertGreaterThan(height(of: row(), in: nil, at: .xLarge), height(of: row(), in: nil, at: .medium))
        XCTAssertLessThan(height(of: row(), in: nil, at: .xSmall), height(of: row(), in: nil, at: .medium))
    }

    /// Native controls take the control size nearest each step's body
    /// size, and none at the steps that already match the platform's.
    func testControlSizeMapping() {
        XCTAssertEqual(AppTextSize.xSmall.controlSize, .small)
        XCTAssertNil(AppTextSize.small.controlSize)
        XCTAssertNil(AppTextSize.medium.controlSize)
        XCTAssertEqual(AppTextSize.large.controlSize, .extraLarge)
        XCTAssertEqual(AppTextSize.xLarge.controlSize, .extraLarge)
    }

    /// The scene root applies that control size, and at a step with none
    /// leaves an explicit one from above untouched.
    func testSceneRootAppliesTheControlSize() async throws {
        let saved = AppTextSizeStore.shared.interface
        defer { AppTextSizeStore.shared.interface = saved }
        let box = ControlSizeBox()
        let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ControlSizeProbe(box: box).appTextSize().controlSize(.mini))
        defer { window.contentView = nil }

        AppTextSizeStore.shared.interface = .medium
        try await waitFor { box.size == .mini }
        AppTextSizeStore.shared.interface = .xLarge
        try await waitFor { box.size == .extraLarge }
        AppTextSizeStore.shared.interface = .xSmall
        try await waitFor { box.size == .small }
    }

    // MARK: - Measuring

    private func height(of view: some View, in containerFont: Font?, at size: AppTextSize) -> CGFloat {
        fitting(view, in: containerFont, at: size).height
    }

    private func width(of view: some View, in containerFont: Font?, at size: AppTextSize) -> CGFloat {
        fitting(view, in: containerFont, at: size).width
    }

    private func fitting(_ view: some View, in containerFont: Font?, at size: AppTextSize) -> CGSize {
        NSHostingView(rootView: view
            .fixedSize()
            .font(containerFont)
            .environment(\.interfaceTextSize, size)
        ).fittingSize
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }
}

@MainActor
private final class ControlSizeBox {
    var size: ControlSize?
}

private struct ControlSizeProbe: View {
    let box: ControlSizeBox
    @Environment(\.controlSize) private var size

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = (box.size = size)
        Color.clear.frame(width: 10, height: 10)
    }
}
