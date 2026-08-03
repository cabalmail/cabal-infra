#if os(iOS)
import AppIntents
import UIKit
import CabalmailKit

/// "Create a Cabalmail address" with a chosen shape — e.g. username "acme",
/// subdomain "complaints" → `acme@complaints.<domain>`. Dictated input is
/// normalized to the `/new` Lambda's local-part / DNS-label rules
/// (`AddressMint.normalizeLabel`), and the result is copied to the
/// clipboard like the random variant.
struct CreateNamedAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Address"
    static let description = IntentDescription(
        "Creates a Cabalmail address with the username and subdomain you choose, then copies it.",
        categoryName: "Addresses"
    )

    @Parameter(title: "Username", requestValueDialog: "What should go before the @?")
    var username: String

    @Parameter(title: "Subdomain", requestValueDialog: "What subdomain should go after the @?")
    var subdomain: String

    /// Resolves silently when the account can mint on exactly one apex;
    /// otherwise Siri asks (see `MailDomainQuery.defaultResult`).
    @Parameter(title: "Domain")
    var domain: MailDomainEntity

    @Parameter(title: "Comment")
    var comment: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create \(\.$username) @ \(\.$subdomain) . \(\.$domain)") {
            \.$comment
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let local = AddressMint.normalizeLabel(username) else {
            throw $username.needsValueError("What should go before the @?")
        }
        guard let sub = AddressMint.normalizeLabel(subdomain) else {
            throw $subdomain.needsValueError("What subdomain should go after the @?")
        }
        let client = try await IntentBridge.shared.activeClient()
        let address = "\(local)@\(sub).\(domain.id)"
        let trimmedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.requestAddress(
                username: local,
                subdomain: sub,
                tld: domain.id,
                comment: (trimmedComment?.isEmpty ?? true) ? nil : trimmedComment,
                address: address
            )
        } catch {
            throw IntentError.friendly(error)
        }
        UIPasteboard.general.string = address
        return .result(
            value: address,
            dialog: "Created \(address) and copied it to the clipboard."
        )
    }
}
#endif
