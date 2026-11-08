#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import CabalmailUI

/// 1.44.1 on iPhone: tapping back from INBOX to the folder list hung the app
/// until the watchdog killed it (`0x8BADF00D`, main thread pinned in layout
/// under the navigation transition).
///
/// The folder list's `searchDrawerScrollRoom` pads a short list to its
/// tallest viewport, and it worked the rows' height out as the reported
/// content height minus the margin it had just set. Under the pop, the
/// content height in each report was laid out with the margin before that
/// one, so every step overshot and the margin went round a six-step cycle
/// (0, 54, 333, 558, 504, 225, 0, ...) without end. These host the real
/// modifier in the shape the iPhone Mail tab gives it - a collapsed
/// `NavigationSplitView` inside a `TabView`, the folder pills above a short
/// `List` with a sidebar `.searchable` - start on the message list, and pop
/// back to the folders the way the back button does.
@MainActor
final class SearchDrawerScrollRoomLoopTests: XCTestCase {

    /// What the harness saw: each margin the modifier applied, and the list's
    /// scroll geometry as of the last report.
    @MainActor
    @Observable
    final class Recorder {
        /// Past this many margins the loop is assumed endless: the harness
        /// drops the modifier, which is the only way to stop it, so the
        /// regressed shape fails these tests instead of hanging the runner
        /// with its main thread pinned (which is what it did).
        static let tripWire = 40
        var margins: [CGFloat] = [] {
            didSet { if margins.count >= Self.tripWire { tripped = true } }
        }
        var tripped = false
        var content: CGFloat = 0
        var insets: CGFloat = 0
        var tallestViewport: CGFloat = 0
    }

    private struct ListGeometry: Equatable {
        var viewport: CGFloat
        var content: CGFloat
        var insets: CGFloat
    }

    /// The modifier under test, recording each margin, until the trip wire
    /// takes it off the list.
    private struct TripWired: ViewModifier {
        let recorder: Recorder

        @ViewBuilder
        func body(content: Content) -> some View {
            if recorder.tripped {
                content
            } else {
                content.modifier(SearchDrawerScrollRoomModifier { margin in
                    recorder.margins.append(margin)
                })
            }
        }
    }

    private struct Harness: View {
        let recorder: Recorder
        let folderCount: Int
        @State private var column: NavigationSplitViewColumn = .content
        @State private var filter = ""

        var body: some View {
            TabView {
                Tab("Mail", systemImage: "envelope") {
                    NavigationSplitView(
                        columnVisibility: .constant(.doubleColumn),
                        preferredCompactColumn: $column
                    ) {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Unread")
                                Text("Flagged")
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            List {
                                ForEach(0..<folderCount, id: \.self) { index in
                                    Text("Folder \(index)")
                                }
                            }
                            .navigationTitle("Folders")
                            .searchable(text: $filter, placement: .sidebar, prompt: "Filter folders")
                            .modifier(TripWired(recorder: recorder))
                            // Outside the modifier: what the list ends up as.
                            .onScrollGeometryChange(for: ListGeometry.self) { geometry in
                                ListGeometry(
                                    viewport: geometry.containerSize.height,
                                    content: geometry.contentSize.height,
                                    insets: geometry.contentInsets.top + geometry.contentInsets.bottom
                                )
                            } action: { _, new in
                                recorder.content = new.content
                                recorder.insets = new.insets
                                recorder.tallestViewport = max(recorder.tallestViewport, new.viewport)
                            }
                        }
                    } content: {
                        ScrollView {
                            LazyVStack {
                                ForEach(0..<80, id: \.self) { index in
                                    Text("Message \(index)").frame(maxWidth: .infinity, minHeight: 60)
                                }
                            }
                        }
                        .navigationTitle("INBOX")
                    } detail: {
                        Text("Reader")
                    }
                }
                Tab("Feeds", systemImage: "dot.radiowaves.up.forward") {
                    Text("Feeds")
                }
            }
            .environment(\.horizontalSizeClass, .compact)
        }
    }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        var found: [UINavigationController] = []
        if let navigation = controller as? UINavigationController { found.append(navigation) }
        for child in controller.children { found += navigationControllers(in: child) }
        return found
    }

    /// Shows the harness on the message list, then pops to the folder list
    /// the way the back button does and lets it sit.
    private func popToFolders(folderCount: Int) throws -> Recorder {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let recorder = Recorder()
        let host = UIHostingController(rootView: Harness(recorder: recorder, folderCount: folderCount))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        spin(1)

        let stack = try XCTUnwrap(
            navigationControllers(in: host).first { $0.viewControllers.count > 1 },
            "the collapsed split should open on the message list, with the folders under it"
        )
        stack.popViewController(animated: true)
        spin(2)
        return recorder
    }

    /// The hang: a short list after the pop. The margin settles in a couple
    /// of steps and then stays put; the regressed shape kept changing it
    /// every frame for as long as the list was up.
    func testPopToAShortFolderListSettlesTheMargin() throws {
        let recorder = try popToFolders(folderCount: 6)
        let settled = recorder.margins.count
        spin(1)

        XCTAssertFalse(recorder.tripped, "margin changed \(Recorder.tripWire) times: the loop that hung 1.44.1")
        XCTAssertLessThanOrEqual(settled, 3, "margin kept changing after the pop: \(recorder.margins.prefix(24))")
        XCTAssertEqual(recorder.margins.count, settled, "margin still changing a second after it settled")
        // And it still does its job: the padded list exactly fills its
        // tallest viewport, so with the drawer shown it scrolls by the
        // drawer's height and with it tucked it doesn't scroll at all.
        XCTAssertGreaterThan(recorder.margins.last ?? 0, 0, "a short list should be padded")
        XCTAssertEqual(recorder.content + recorder.insets, recorder.tallestViewport, accuracy: 1)
    }

    /// A list longer than the screen needs no room and gets none.
    func testPopToALongFolderListAddsNoMargin() throws {
        let recorder = try popToFolders(folderCount: 40)
        XCTAssertEqual(recorder.margins, [], "an overflowing list should never be padded")
    }
}
#endif
