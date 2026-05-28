import Contacts
import Foundation

/// Local-only read access to the system address book. Backs the
/// "supplement received-mail addresses with the user's own name for
/// them" UX without sending any contact data over the wire — every
/// lookup is satisfied from `CNContactStore` on device.
///
/// See `docs/0.9.x/apple-contacts-integration-plan.md` for the broader
/// integration plan. Phase 1 ships the protocol + live actor only;
/// consumers (message list, message detail, avatar) wire up in Phase 2.
public protocol ContactsStore: Sendable {
    /// Current authorization state. Cheap; backed by
    /// `CNContactStore.authorizationStatus`.
    var authorizationStatus: ContactsAuthorizationStatus { get async }

    /// Prompts for access if not yet determined. Returns true when the
    /// resulting state is `.authorized` or `.limited`. Idempotent —
    /// safe to call on every app launch.
    func requestAccess() async -> Bool

    /// The user's own name for this correspondent, if Contacts has one.
    /// Never prompts; callers must invoke `requestAccess` first. Returns
    /// nil when authorization isn't granted, no contact matches, or the
    /// match has no usable name component.
    func displayName(for address: EmailAddress) async -> String?

    /// Thumbnail-sized photo data for this correspondent, if Contacts
    /// has one. `CNContact.thumbnailImageData` — typically a few KB,
    /// suitable for a 40pt avatar without further downscaling.
    func photoData(for address: EmailAddress) async -> Data?

    /// One `RecipientSuggestion` per (contact, email) pair across the
    /// authorized address book. A contact with three emails contributes
    /// three rows; duplicates by email are removed. Returns an empty
    /// array when access isn't granted. Callers should expect this to
    /// be cached for the session — invoking it from compose-view
    /// `.task` is fine.
    func allEntries() async -> [RecipientSuggestion]
}

/// Mirror of `CNAuthorizationStatus` exposed without dragging the
/// Contacts framework into every consumer. The `.limited` case (iOS
/// 18+/macOS 14+) is treated as accessible: the user has elected a
/// subset of contacts, and our enrichment should work against that
/// subset just like full access.
public enum ContactsAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case limited

    public var isAccessible: Bool {
        switch self {
        case .authorized, .limited:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        }
    }

    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .limited: self = .limited
        @unknown default: self = .denied
        }
    }
}

/// `CNContactStore`-backed implementation. Holds a per-session
/// in-memory cache keyed by lowercased `mailbox@host`; cache entries
/// record misses too so a known-unknown address doesn't trigger a
/// fresh framework query on every render of the same row.
///
/// Actor isolation serializes framework reads; `CNContactStore`
/// unified queries are sync and fast (low milliseconds on a populated
/// book), so a single executor is adequate for the message-list /
/// detail / compose load.
public actor LiveContactsStore: ContactsStore {
    private let store = CNContactStore()
    private var cache: [String: ContactLookup] = [:]
    /// Session cache for `allEntries`. Populated lazily on first call.
    /// We don't subscribe to `CNContactStoreDidChange` — the cost of a
    /// rebuild-per-launch is small and saves the complexity of an
    /// invalidation path. Compose autocomplete sees newly-added
    /// contacts on the next launch.
    private var allEntriesCache: [RecipientSuggestion]?

    public init() {}

    public var authorizationStatus: ContactsAuthorizationStatus {
        ContactsAuthorizationStatus(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func requestAccess() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }

    public func displayName(for address: EmailAddress) async -> String? {
        lookup(for: address).displayName
    }

    public func photoData(for address: EmailAddress) async -> Data? {
        lookup(for: address).photoData
    }

    public func allEntries() async -> [RecipientSuggestion] {
        guard authorizationStatusIsAccessible else { return [] }
        if let cached = allEntriesCache { return cached }
        let entries = fetchAllEntries()
        allEntriesCache = entries
        return entries
    }

    private func fetchAllEntries() -> [RecipientSuggestion] {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var seenEmails = Set<String>()
        var collected: [RecipientSuggestion] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = Self.bestDisplayName(for: contact)
                for emailEntry in contact.emailAddresses {
                    let email = (emailEntry.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !email.isEmpty else { continue }
                    let key = email.lowercased()
                    guard seenEmails.insert(key).inserted else { continue }
                    collected.append(RecipientSuggestion(name: name, email: email))
                }
            }
        } catch {
            return []
        }
        return collected
    }

    private func lookup(for address: EmailAddress) -> ContactLookup {
        guard authorizationStatusIsAccessible else { return .miss }
        let key = address.contactsCacheKey
        if let cached = cache[key] { return cached }
        let fetched = fetchFromStore(for: address)
        cache[key] = fetched
        return fetched
    }

    /// Local copy of the authorization check to keep `lookup` synchronous
    /// inside the actor (avoiding an `await` on the async accessor).
    private var authorizationStatusIsAccessible: Bool {
        ContactsAuthorizationStatus(CNContactStore.authorizationStatus(for: .contacts)).isAccessible
    }

    private func fetchFromStore(for address: EmailAddress) -> ContactLookup {
        let emailString = "\(address.mailbox)@\(address.host)"
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: emailString)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        } catch {
            return .miss
        }
        guard let contact = contacts.first else { return .miss }
        return ContactLookup(
            displayName: Self.bestDisplayName(for: contact),
            photoData: contact.thumbnailImageData
        )
    }

    /// Picks the most user-meaningful label for a contact, falling
    /// back through person name -> nickname -> organization. Exposed
    /// as a static so tests can drive it directly with
    /// `CNMutableContact` fixtures without standing up an actor.
    static func bestDisplayName(for contact: CNContact) -> String? {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName),
           !formatted.isEmpty {
            return formatted
        }
        if !contact.nickname.isEmpty { return contact.nickname }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        return nil
    }
}

/// Returns nil for everything. Useful as the wired-in default before
/// the consumer requests authorization, in previews, and in tests that
/// don't care about contacts behavior.
public struct NoopContactsStore: ContactsStore {
    public init() {}
    public var authorizationStatus: ContactsAuthorizationStatus { .denied }
    public func requestAccess() async -> Bool { false }
    public func displayName(for address: EmailAddress) async -> String? { nil }
    public func photoData(for address: EmailAddress) async -> Data? { nil }
    public func allEntries() async -> [RecipientSuggestion] { [] }
}

struct ContactLookup: Sendable, Equatable {
    let displayName: String?
    let photoData: Data?

    static let miss = ContactLookup(displayName: nil, photoData: nil)
}

extension EmailAddress {
    /// Cache key for contacts lookups. Case-folds both halves of the
    /// address — RFC 5321 says the local part is case-sensitive in
    /// principle but in practice virtually no mail server treats it
    /// that way, and the cache would otherwise miss on `Jdoe@x` vs
    /// `jdoe@x`.
    var contactsCacheKey: String {
        "\(mailbox.lowercased())@\(host.lowercased())"
    }
}
