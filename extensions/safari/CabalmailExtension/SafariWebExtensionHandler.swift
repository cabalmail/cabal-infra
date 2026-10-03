// Native side of the Safari Web Extension. The extension's logic lives
// entirely in the bundled WebExtension (Resources/); native messaging is
// unused here, so this handler only acknowledges requests.
//
// It stays that way deliberately. The messages the extension does send --
// `get-control-domain` and the private-link token resolution (#1765) --
// read the Cabalmail mail app's App Group container, which this standalone
// host is not a member of; there is no domain and no token row for it to
// answer with. Both are answered by the appex embedded in the mail app
// (apple/CabalmailMacWebExtension/SafariWebExtensionHandler.swift), and the
// app only chooses the token fragment form when that embedded extension is
// the one enabled.

import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}
