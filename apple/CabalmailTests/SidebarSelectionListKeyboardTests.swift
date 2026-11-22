#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CabalmailKit
@testable import CabalmailUI

/// The Mac sidebar's list under the arrow keys: one selection moves down the
/// mail folders and on into the feeds, past the rows that are not selectable
/// (a section's header, its filter pills), and back up.
///
/// The list is the real one (`SidebarSelectionList`) with the real feed rows
/// (`FeedSidebarContent`), hosted offscreen; the keys go to its table view
/// directly, so nothing is posted to the display. The same list with the
/// feed rows drawn as buttons, as the iPad's split draws them, is the
/// control: there the arrow keys stop at the last folder.
@MainActor
final class SidebarSelectionListKeyboardTests: XCTestCase {
    /// A window's two selections. A folder pick closes the feed list and a
    /// feed pick clears the folder, as the navigator does
    /// (`SidebarSelectionWindowTests`).
    @Observable
    @MainActor
    final class Held {
        var folder: Folder?
        var feedScope: RssItemScope?

        var folderBinding: Binding<Folder?> {
            Binding(get: { self.folder }, set: { picked in
                self.folder = picked
                if picked != nil { self.feedScope = nil }
            })
        }

        var feedBinding: Binding<RssItemScope?> {
            Binding(get: { self.feedScope }, set: { picked in
                self.feedScope = picked
                if picked != nil { self.folder = nil }
            })
        }

        /// What the sidebar shows selected, in words.
        var place: String {
            if let feedScope { return "feed " + feedScope.token }
            return folder.map { "folder " + $0.path } ?? "nothing"
        }
    }

    private static let folders = [
        Folder(path: "INBOX", isSubscribed: true), Folder(path: "Archive", isSubscribed: true),
    ]

    private static let feedRows: [FeedSidebarRow] = [
        FeedSidebarRow(
            kind: .folder(RssFolder(folderId: "tech", name: "Tech")), depth: 0, hasChildren: true, unread: 2, total: 9
        ),
        FeedSidebarRow(
            kind: .subscription(
                RssSubscription(subscriptionId: "s", feedId: "f", folderId: "tech", customTitle: "Swift")
            ),
            depth: 1, hasChildren: false, unread: 2, total: 9
        ),
    ]

    /// The mail sidebar's shape: a Mail section whose first row is its
    /// filter pills, then a Feeds section whose first row is its own.
    private struct Sidebar: View {
        let held: Held
        let feedStyle: FeedSidebarContent<Text>.Style
        let feedModel: FeedSidebarViewModel
        let preferences: Preferences

        var body: some View {
            SidebarSelectionList(
                folder: held.folderBinding, feedScope: held.feedBinding,
                folders: SidebarSelectionListKeyboardTests.folders
            ) {
                Section {
                    Text("Subscribed  Unread")
                    ForEach(SidebarSelectionListKeyboardTests.folders) { folder in
                        Text(folder.name).sidebarFolderRow(folder)
                    }
                } header: {
                    Text("Mail")
                }
                Section {
                    FeedSidebarContent(
                        style: feedStyle, model: feedModel, selection: held.feedBinding,
                        rows: SidebarSelectionListKeyboardTests.feedRows,
                        isCollapsed: { _ in false }, toggleCollapse: { _ in },
                        actions: FeedManagementActions(), management: nil,
                        leading: { Text("Unread") }
                    )
                } header: {
                    Text("Feeds")
                }
            }
            .listStyle(.sidebar)
            .environment(preferences)
        }
    }

    private var window: NSWindow!

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// Hosts the sidebar offscreen with INBOX selected and returns its table.
    private func host(_ held: Held, feedStyle: FeedSidebarContent<Text>.Style) async throws -> NSTableView {
        held.folder = Self.folders[0]
        let sidebar = Sidebar(
            held: held, feedStyle: feedStyle, feedModel: FeedSidebarViewModel(store: nil, engine: nil),
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
        let size = NSSize(width: 320, height: 520)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: sidebar.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        var table: NSTableView?
        try await waitUntilOnMainActor {
            table = self.window.contentView.flatMap(Self.table(in:))
            return (table?.numberOfRows ?? 0) > 0 && table?.selectedRow != -1
        }
        let found = try XCTUnwrap(table)
        window.makeFirstResponder(found)
        return found
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(table(in:)).first
    }

    /// Presses an arrow key in the list and waits for the selection to move.
    /// Returns where the sidebar is afterwards.
    private func press(_ key: Arrow, in table: NSTableView, _ held: Held) async throws -> String {
        let before = held.place
        let characters = String(UnicodeScalar(key.function).map(Character.init) ?? " ")
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key.code
        ))
        table.keyDown(with: event)
        // A key that moves nothing is a result too, so this waits and reads
        // rather than failing on a timeout.
        let deadline = ContinuousClock.now + .seconds(1)
        while held.place == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return held.place
    }

    private enum Arrow {
        case downward, upward

        var code: UInt16 { self == .downward ? 125 : 126 }
        var function: Int { self == .downward ? NSDownArrowFunctionKey : NSUpArrowFunctionKey }
    }

    func testTheArrowKeysMoveThroughTheFoldersAndOnIntoTheFeeds() async throws {
        let held = Held()
        let table = try await host(held, feedStyle: .sidebarSelection)
        XCTAssertEqual(held.place, "folder INBOX")

        var walked: [String] = []
        for _ in 0..<4 { walked.append(try await press(.downward, in: table, held)) }

        XCTAssertEqual(walked, ["folder Archive", "feed all", "feed folder:tech", "feed sub:s"])

        // The last row: another press stays put.
        let atEnd = try await press(.downward, in: table, held)
        XCTAssertEqual(atEnd, "feed sub:s")

        walked = []
        for _ in 0..<4 { walked.append(try await press(.upward, in: table, held)) }

        XCTAssertEqual(walked, ["feed folder:tech", "feed all", "folder Archive", "folder INBOX"])
    }

    /// The control: with the feed rows drawn as buttons, as before, the
    /// arrow keys stop at the last folder.
    func testTheArrowKeysStopAtTheLastFolderWhereFeedsAreButtons() async throws {
        let held = Held()
        let table = try await host(held, feedStyle: .rowButtons)

        var walked: [String] = []
        for _ in 0..<3 { walked.append(try await press(.downward, in: table, held)) }

        XCTAssertEqual(walked, ["folder Archive", "folder Archive", "folder Archive"])
        XCTAssertNil(held.feedScope)
    }

    /// The row the list highlights follows the window, not only the keys:
    /// a feed opened from elsewhere (a banner, the list's own switcher)
    /// selects its row.
    func testAFeedOpenedElsewhereSelectsItsRow() async throws {
        let held = Held()
        let table = try await host(held, feedStyle: .sidebarSelection)
        let inboxRow = table.selectedRow

        held.feedBinding.wrappedValue = .subscription("s")

        try await waitUntilOnMainActor { table.selectedRow != inboxRow && table.selectedRow != -1 }
        XCTAssertEqual(table.selectedRow, table.numberOfRows - 1, "the subscription is the last row")
    }
}
#endif
