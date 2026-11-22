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
    /// Donates feed items, which have an entry type of their own: a
    /// message's entry is built from an envelope and named by folder and UID.
    func indexFeedItems(_ entries: [SpotlightFeedEntry]) async throws
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

    public func indexFeedItems(_ entries: [SpotlightFeedEntry]) async throws {
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
    /// Maps the value type onto CoreSpotlight's attribute set.
    ///
    /// The content type is deliberately `.text`, NOT `.emailMessage`: macOS
    /// Spotlight routes a clicked result whose content type is
    /// `public.email-message` (or its parent `public.message`) to the
    /// system's default mail handler — Apple Mail — regardless of the
    /// donating app's `CoreSpotlightContinuation` declaration. Verified
    /// empirically with a clean-room probe app on macOS 26 (2026-08-12):
    /// email-typed items opened Mail and the donating app's continuation
    /// never fired; `.text`-typed items opened the donating app and
    /// delivered the activity. The mail-specific attributes (subject,
    /// author/recipient names and addresses) remain settable and searchable
    /// under any content type.
    func searchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        // iOS 17+ shows a donated item only when `displayName` is set;
        // `title` alone no longer surfaces it (macOS still honors `title`,
        // which is how this shipped looking correct on the Mac).
        attributes.displayName = title
        attributes.subject = title
        attributes.authorNames = authorNames
        attributes.authorEmailAddresses = authorEmailAddresses
        attributes.recipientNames = recipientNames
        attributes.recipientEmailAddresses = recipientEmailAddresses
        attributes.contentCreationDate = date
        attributes.contentDescription = contentDescription
        attributes.textContent = textContent
        // No expirationDate override: `.distantFuture` has a history of
        // making items invisible, and the default ~30-day expiry is
        // refreshed by the session sweep (top pages) and by every folder
        // open, so mail the user actually touches stays indexed.
        return CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}

extension SpotlightFeedEntry {
    /// Maps the value type onto CoreSpotlight's attribute set.
    ///
    /// `.text`, as a message's item is, and for the reason given there: it
    /// is the content type under which a chosen result comes back to the
    /// app that donated it. `displayName` is set for the same reason too.
    /// The item's web address is deliberately not donated: a result opens
    /// the item in the app, not the page in a browser.
    func searchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.displayName = title
        attributes.authorNames = authorNames
        attributes.contentCreationDate = date
        attributes.contentDescription = contentDescription
        attributes.textContent = textContent
        // The default expiry stands, as for a message: the session-start
        // refresh donates each feed's newest items again.
        return CSSearchableItem(
            uniqueIdentifier: uniqueIdentifier,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}
#endif
