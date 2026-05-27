import Foundation
import CabalmailKit

// MARK: - EmailAddress parsing

extension EmailAddress {
    /// Lenient `user@host` parser. No display-name support; the Phase 5
    /// compose view only needs the raw address form — display names are a
    /// Phase 5.1 enhancement alongside contact autocomplete.
    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let atIndex = trimmed.firstIndex(of: "@") else { return nil }
        let mailbox = String(trimmed[..<atIndex])
        let host = String(trimmed[trimmed.index(after: atIndex)...])
        guard !mailbox.isEmpty, !host.isEmpty, host.contains(".") else { return nil }
        self.init(name: nil, mailbox: mailbox, host: host)
    }
}
