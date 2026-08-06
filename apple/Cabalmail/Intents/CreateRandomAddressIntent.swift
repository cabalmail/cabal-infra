#if os(iOS)
import AppIntents
import CabalmailKit

/// "Get a new random address from Cabalmail." Mints
/// `<random>@<random>.<domain>` — the same 8+8 alphanumeric shape as the
/// Random button in `NewAddressSheet` — and copies it to the clipboard so
/// the user can paste it straight into whatever form asked for an email.
/// `ForegroundContinuableIntent` because the copy may need a foreground
/// hop (see `finishAddressCreation`).
struct CreateRandomAddressIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Get Random Address"
    static let description = IntentDescription(
        "Creates a new random Cabalmail address and copies it to the clipboard.",
        categoryName: "Addresses"
    )

    /// Resolves silently when the account can mint on exactly one apex;
    /// otherwise Siri asks (see `MailDomainQuery.defaultResult`).
    @Parameter(title: "Domain")
    var domain: MailDomainEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get a random address on \(\.$domain)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let client = try await IntentBridge.shared.activeClient()
        let username = AddressMint.randomLabel()
        let subdomain = AddressMint.randomLabel()
        let address = "\(username)@\(subdomain).\(domain.id)"
        do {
            try await client.requestAddress(
                username: username,
                subdomain: subdomain,
                tld: domain.id,
                comment: nil,
                address: address
            )
        } catch {
            throw IntentError.friendly(error)
        }
        return await finishAddressCreation(address)
    }
}
#endif
