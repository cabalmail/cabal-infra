#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import CabalmailUI

/// The tripwire for the iPhone Duo code. Every Duo API is compiled only
/// when the iOS SDK's SwiftUICore is 8.0.85 or later (iOS 27.1), because
/// the compiler version cannot tell 27.0 from 27.1. If CI's Xcode ever falls
/// back to one without the 27.1 SDK, that code compiles out silently and
/// the shipped app runs boxed in on both of the Duo's displays, with every
/// fold fix gone. This fails first.
@MainActor
final class FoldAPICompiledTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testTheFoldCodeIsCompiledIntoTheIOSApp() {
        XCTAssertTrue(
            FoldAPI.isCompiled,
            "the iOS 27.1 fold code compiled out: this Xcode's iOS SDK predates 27.1 (SwiftUICore 8.0.85)"
        )
    }

    /// A window with no fold, hosted for real, publishes no fold. Every
    /// iPhone, and an iPhone Duo flat or closed, is this case. On an iOS 27.1
    /// runtime (the advisory iPhone Duo leg) the guarded region read runs on
    /// every layout pass; the hinge read stays off, since it is on only while
    /// a fold is held. On an older runtime, which is where the required iOS
    /// leg's iPhone runs, the guarded reads are skipped and this checks only
    /// the unguarded default.
    func testAnUnfoldedWindowPublishesNoFold() async throws {
        let probe = FoldStateProbe()
        let root = Color.clear
            .background { FoldStateReporter(probe: probe) }
            .foldGeometry()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        self.window = window
        for _ in 0..<300 where probe.reported == nil {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        // Past the confirming pass, so a fold the reader settled would show.
        try await Task.sleep(for: FoldAPI.confirmDelay * 4)
        XCTAssertEqual(probe.reported, FoldState.none)
    }
}

@MainActor
private final class FoldStateProbe {
    var reported: FoldState?
}

private struct FoldStateReporter: View {
    let probe: FoldStateProbe
    @Environment(\.foldState) private var fold

    var body: some View {
        Color.clear
            .onAppear { probe.reported = fold }
            .onChange(of: fold) { _, new in probe.reported = new }
    }
}
#endif
