#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import CabalmailUI

/// Where `verticalBars()` reads the strip from. On an ordinary iPhone, and
/// on the iOS 27.0 runtime the required iOS leg runs on, nothing is
/// vertical. On iPhone Duo's closed outer display, which is where the
/// advisory Duo leg's simulator sits, the system puts every bar in a strip
/// at the side, and a window hosted in the test app's own scene reads it.
@MainActor
final class VerticalBarsTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testTheRootReportsWhatTheSystemDoesWithTheBars() async throws {
        let probe = VerticalBarsProbe()
        let root = Color.clear
            .background { VerticalBarsReporter(probe: probe) }
            .verticalBars()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        self.window = window
        for _ in 0..<300 where probe.reported == nil {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let reported = try XCTUnwrap(probe.reported, "the reporter never appeared")
        let systemEdge = window.traitCollection.verticalBarEdgeIsSpecified
        XCTAssertEqual(reported.vertical, systemEdge, "the root agrees with the window's own trait")
        XCTAssertEqual(reported.vertical, reported.edge != nil)
    }
}

@MainActor
private final class VerticalBarsProbe {
    var reported: (vertical: Bool, edge: HorizontalEdge?)?
}

private struct VerticalBarsReporter: View {
    let probe: VerticalBarsProbe
    @Environment(\.barsAreVertical) private var vertical
    @Environment(\.verticalBarEdge) private var edge

    var body: some View {
        Color.clear
            .onAppear { probe.reported = (vertical, edge) }
            .onChange(of: vertical) { _, new in probe.reported = (new, edge) }
    }
}

private extension UITraitCollection {
    /// The window's own reading, through UIKit, of whether the system puts
    /// its bars in a side strip: unspecified on hosts and SDKs that never do.
    var verticalBarEdgeIsSpecified: Bool {
        #if canImport(SwiftUICore, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return verticalBarEdge != .unspecified
        }
        #endif
        return false
    }
}
#endif
