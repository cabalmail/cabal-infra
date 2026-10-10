import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// The tracking modifier on a real scroll view (`tracksListPlace`), hosted
/// so layout and scrolling run: the landing scrolls the list to its row by
/// the row's slot as it is then, and the list's own scrolling reaches the
/// tracker as a top row. The list here is the virtualized list's shape, one
/// fixed-height row per slot, without its rows' content.
@MainActor
final class ListPlaceTrackingHostedTests: XCTestCase {
    private static let rowHeight: CGFloat = 40

    /// What the test reads from the hosted list, and scrolls it with.
    @Observable
    @MainActor
    final class Probe {
        var offset: CGFloat = 0
        var proxy: ScrollViewProxy?
    }

    private struct Host: View {
        let model: MessageListViewModel
        let tracker: ListPlaceTracker
        let navigator: SceneNavigator
        let probe: Probe

        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rowSlots(count: model.slotCount), id: \.self) { _ in
                            Color.clear.frame(height: ListPlaceTrackingHostedTests.rowHeight)
                        }
                    }
                }
                .tracksListPlace(
                    tracker, model: model, rowHeight: ListPlaceTrackingHostedTests.rowHeight, proxy: proxy
                )
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    probe.offset = offset
                }
                .onAppear { probe.proxy = proxy }
            }
            .environment(navigator)
        }
    }

    private var world: ListPagingWorld!
    private var navigator: SceneNavigator!
    private var tracker: ListPlaceTracker!
    private var probe: Probe!
    private var host: HostedViewHarness!

    override func setUp() async throws {
        try await super.setUp()
        world = ListPagingWorld()
        navigator = SceneNavigator(coordinator: { nil }, hasClient: { true }, seed: .mail)
        tracker = ListPlaceTracker()
        probe = Probe()
    }

    override func tearDown() async throws {
        host?.close()
        host = nil
        await world.tearDown()
        world = nil
        navigator = nil
        tracker = nil
        probe = nil
        try await super.tearDown()
    }

    private func anchor(index: Int, uid: UInt32) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: ListPagingWorld.folderPath, messageID: ListPagingWorld.messageID(uid), uid: uid, index: index
        ))
    }

    private func mount(_ model: MessageListViewModel) async throws {
        host = HostedViewHarness { [tracker, navigator, probe] in
            Host(model: model, tracker: tracker!, navigator: navigator!, probe: probe!)
        }
        try await host.settle()
    }

    /// A full swipe replaced the row at the place since it was recorded, so
    /// its slot has a new identity: the landing still scrolls to it.
    func testTheLandingScrollsTheListToItsRowsSlot() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        model.replaceRows(showing: [MessageRef](), alsoAt: [200])
        navigator.restores.parkListAnchor(try anchor(index: 200, uid: 800))
        try await mount(model)

        tracker.land(model: model, in: navigator)

        let scrolled = try await host.eventually { abs(self.probe.offset - 200 * Self.rowHeight) < 1 }
        XCTAssertTrue(scrolled, "the list is at \(probe.offset), not at row 200")
        XCTAssertEqual(navigator.listHold.place, try anchor(index: 200, uid: 800))
    }

    /// The list scrolling on its own (the user's scroll, driven here through
    /// the scroll view) is recorded as its top row.
    func testTheListsScrollIsRecordedAsItsTopRow() async throws {
        let model = try await world.openedList(preloaded: 250, stampsMessageIDs: true)
        try await mount(model)
        tracker.land(model: model, in: navigator)

        probe.proxy?.scrollTo(model.rowSlot(at: 30), anchor: .top)

        let recorded = try await host.eventually { self.navigator.listHold.place?.index == 30 }
        XCTAssertTrue(recorded, "the place is \(String(describing: navigator.listHold.place))")
        XCTAssertEqual(navigator.listHold.place, try anchor(index: 30, uid: 970))
    }
}
