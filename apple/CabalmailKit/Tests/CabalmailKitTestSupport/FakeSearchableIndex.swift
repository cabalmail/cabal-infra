import Foundation
import CabalmailKit

/// Records every `SearchableIndexing` operation for assertions. An actor so
/// the indexer's concurrent sweep tasks can't race the recording.
public actor FakeSearchableIndex: SearchableIndexing {
    public nonisolated var isAvailable: Bool { true }

    public init() {}

    public private(set) var indexedBatches: [[SpotlightEntry]] = []
    public private(set) var indexedFeedBatches: [[SpotlightFeedEntry]] = []
    public private(set) var deletedIdentifiers: [[String]] = []
    public private(set) var deletedDomains: [[String]] = []
    public private(set) var deleteAllCount = 0
    /// Every operation in the order it arrived, for the tests that pin an
    /// order between kinds: "mail", "feed", "identifiers", "domains", "all".
    public private(set) var operations: [String] = []

    public var indexedEntries: [SpotlightEntry] { indexedBatches.flatMap { $0 } }
    public var indexedFeedEntries: [SpotlightFeedEntry] { indexedFeedBatches.flatMap { $0 } }

    public func index(_ entries: [SpotlightEntry]) async throws {
        indexedBatches.append(entries)
        operations.append("mail")
    }

    public func indexFeedItems(_ entries: [SpotlightFeedEntry]) async throws {
        indexedFeedBatches.append(entries)
        operations.append("feed")
    }

    public func deleteIdentifiers(_ identifiers: [String]) async throws {
        deletedIdentifiers.append(identifiers)
        operations.append("identifiers")
    }

    public func deleteDomains(_ domains: [String]) async throws {
        deletedDomains.append(domains)
        operations.append("domains")
    }

    public func deleteAll() async throws {
        deleteAllCount += 1
        operations.append("all")
    }
}
