// Native side of the web extension embedded in the Cabalmail mail app.
// The extension's logic lives entirely in the bundled WebExtension
// (Resources/, built from extensions/ by scripts/sync-vendored.sh); this
// handler answers exactly one native message: which Cabalmail server the
// containing mail app is signed in to, read from the shared App Group so
// the user never types the control domain twice. Unknown messages get an
// empty acknowledgement, matching the standalone host's handler.

import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard message?["kind"] as? String == "get-control-domain" else {
            context.completeRequest(returningItems: nil)
            return
        }

        let response = NSExtensionItem()
        response.userInfo = [
            // JS expects `{ domain: string | null }`; NSNull crosses the
            // bridge as null.
            SFExtensionMessageKey: [
                "domain": ExtensionControlDomainStore.read() as Any? ?? NSNull()
            ]
        ]
        context.completeRequest(returningItems: [response])
    }
}
