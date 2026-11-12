import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// `SearchQuery.keyword`, the custom flag a mail search is narrowed to:
/// `/search_envelopes` takes one palette slot and returns only the messages
/// that carry it, in one folder or across all of them.
final class SearchQueryKeywordTests: XCTestCase {
    private let emptyReply = """
        {"envelopes": [], "total_estimate": 0, "next_cursor": null, "folders_searched": [], "truncated": false}
        """

    private func queryItems(sentFor query: SearchQuery) async throws -> [String: String] {
        let http = RecordingHTTPTransport(responses: [(Data(emptyReply.utf8), 200)])
        let api = URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: http
        )
        _ = try await api.searchEnvelopes(host: "imap.example.com", query: query)
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testTheKeywordIsSentBesideTheOtherCriteria() async throws {
        let sent = try await queryItems(sentFor: SearchQuery(folder: "INBOX", flagged: true, keyword: "cabal-flag-03"))

        XCTAssertEqual(sent["keyword"], "cabal-flag-03")
        XCTAssertEqual(sent["flagged"], "1", "every criterion given is sent; the server requires all of them")
        XCTAssertEqual(sent["folder"], "INBOX")
    }

    func testASearchWithoutAKeywordSendsNone() async throws {
        let sent = try await queryItems(sentFor: SearchQuery(text: "invoice"))

        XCTAssertNil(sent["keyword"])
    }

    /// A long result set is fetched a page at a time, each page a copy of
    /// the query: a copy that lost the keyword would page through every
    /// message instead of the flag's.
    func testEveryPageOfASearchKeepsTheKeyword() {
        let query = SearchQuery(keyword: "cabal-flag-03")

        XCTAssertEqual(query.page(limit: 50, cursor: "next").keyword, "cabal-flag-03")
    }
}
