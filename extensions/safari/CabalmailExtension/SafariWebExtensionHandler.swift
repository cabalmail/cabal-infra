// Native side of the Safari Web Extension. The extension's logic lives
// entirely in the bundled WebExtension (Resources/); native messaging is
// unused for now, so this handler only acknowledges requests. It becomes
// load-bearing if the private-link handoff ever needs the opaque-token
// fallback (docs/1.x/browser-extension-plan.md, Phase 7.2).

import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}
