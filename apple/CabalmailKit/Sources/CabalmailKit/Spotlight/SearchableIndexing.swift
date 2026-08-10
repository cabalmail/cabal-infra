import Foundation
#if canImport(CoreSpotlight)
import CoreSpotlight
import UniformTypeIdentifiers
#endif

/// The slice of Core Spotlight `SpotlightIndexer` needs, as a protocol so
/// tests can record operations against a fake. Everything is on-device:
/// content donated through this surface stays in the local Spotlight index
/// and is never synced off the device (the only off-device path,
/// `NSUserActivity.isEligibleForPublicIndexing`, is not used anywhere).
public protocol SearchableIndexing: Sendable {
    /// False when the platform declines indexing (e.g. some simulators);
    /// the indexer turns itself into a no-op rather than erroring.
    var isAvailable: Bool { get }
    func index(_ entries: [SpotlightEntry]) async throws
    func deleteIdentifiers(_ identifiers: [String]) async throws
    func deleteDomains(_ domains: [String]) async throws
    func deleteAll() async throws
}

#if canImport(CoreSpotlight)
/// Production implementation backed by the process's default
/// `CSSearchableIndex`. Stateless — `CSSearchableIndex.default()` returns
/// the shared thread-safe instance, so a fresh struct per client is free.
public struct LiveSearchableIndex: SearchableIndexing {
    public init() {}

    public var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }

    public func index(_ entries: [SpotlightEntry]) async throws {
        try await CSSearchableIndex.default().indexSearchableItems(entries.map { $0.searchableItem() })
    }

    public func deleteIdentifiers(_ identifiers: [String]) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
    }

    public func deleteDomains(_ domains: [String]) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: domains)
    }

    public func deleteAll() async throws {
        try await CSSearchableIndex.default().deleteAllSearchableItems()
    }
}

extension SpotlightEntry {
    /// Maps the value type onto CoreSpotlight's mail attribute set.
    func searchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .emailMessage)
        attributes.title = title
        attributes.subject = title
        attributes.authorNames = authorNames
        attributes.authorEmailAddresses = authorEmailAddresses
        attributes.recipientNames = recipientNames
        attributes.recipientEmailAddresses = recipientEmailAddresses
        attributes.contentCreationDate = date
        attributes.contentDescription = contentDescription
        attributes.textContent = textContent
        let item = CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // Mail should stay searchable indefinitely, not lapse after Core
        // Spotlight's default ~30-day expiry; the index is pruned explicitly
        // on move / delete / unsubscribe / sign-out instead.
        item.expirationDate = .distantFuture
        return item
    }
}
#endif
