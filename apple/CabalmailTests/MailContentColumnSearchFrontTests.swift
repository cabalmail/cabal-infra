#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CabalmailKit
@testable import CabalmailUI

/// The list column says what a search begun over it would open on while
/// no results are up (`MailContentColumn.onSearchFrontChanged`).
///
/// On the Mac the search results take the column only once a term is
/// typed, so results that asked what was in front as they appeared asked
/// too late: the first search after launch opened on All, and each later
/// one on what the search before it had been over.
///
/// The column is hosted with its search engaged and no search model, which
/// draws no list at all: what it reports cannot come from a list.
@MainActor
final class MailContentColumnSearchFrontTests: XCTestCase {
    private final class Reports {
        var fronts: [SearchScope] = []
    }

    private func column(
        feeds: Bool, folder: Folder?, reports: Reports
    ) -> MailContentColumn<EmptyView> {
        MailContentColumn(
            feedList: feeds
                ? FeedListSelection(scope: .all, selection: .constant(nil), onSwitchScope: { _ in }) : nil,
            isSearching: true,
            folder: folder,
            selection: .constant(nil),
            onSelectionCountChanged: { _ in },
            onSwitchFolder: { _ in },
            onSearchFrontChanged: { reports.fronts.append($0) },
            header: { EmptyView() }
        )
    }

    func testTheColumnSaysWhatIsInFrontWithNoResultsUpAndAgainWhenItChanges() async throws {
        let reports = Reports()
        let inbox = Folder(path: "INBOX", attributes: [], isSubscribed: true)
        let host = NSHostingView(rootView: column(feeds: true, folder: inbox, reports: reports))
        let window = NSWindow(
            contentRect: NSRect(x: -8_000, y: -8_000, width: 320, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        try await waitUntilOnMainActor { reports.fronts == [.feeds] }

        host.rootView = column(feeds: false, folder: inbox, reports: reports)
        try await waitUntilOnMainActor { reports.fronts == [.feeds, .mail] }

        host.rootView = column(feeds: false, folder: nil, reports: reports)
        try await waitUntilOnMainActor { reports.fronts == [.feeds, .mail, .all] }
    }
}
#endif
