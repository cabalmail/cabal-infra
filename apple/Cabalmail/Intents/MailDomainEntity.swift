#if os(iOS)
import AppIntents
import CabalmailKit

/// One apex mail domain the user can mint addresses on. `id` is the domain
/// name itself, matching `MailDomain.id` in the Kit.
struct MailDomainEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mail Domain"
    static let defaultQuery = MailDomainQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct MailDomainQuery: EntityQuery {
    /// Saved shortcuts re-resolve by identifier without a network hop; the
    /// `/new` Lambda is the authority on entitlement anyway.
    func entities(for identifiers: [String]) async throws -> [MailDomainEntity] {
        identifiers.map(MailDomainEntity.init(id:))
    }

    @MainActor
    func suggestedEntities() async throws -> [MailDomainEntity] {
        guard let client = try? await IntentBridge.shared.activeClient() else { return [] }
        return await IntentDomains.visible(client: client).map(MailDomainEntity.init(id:))
    }

    /// A single entitled apex resolves silently; with several, returning nil
    /// makes Siri ask, offering `suggestedEntities()` as the choices.
    @MainActor
    func defaultResult() async -> MailDomainEntity? {
        guard let client = try? await IntentBridge.shared.activeClient() else { return nil }
        let visible = await IntentDomains.visible(client: client)
        guard visible.count == 1, let only = visible.first else { return nil }
        return MailDomainEntity(id: only)
    }
}
#endif
