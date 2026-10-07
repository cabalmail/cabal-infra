// Native side of the web extension embedded in the Cabalmail mail app.
// The extension's logic lives entirely in the bundled WebExtension
// (Resources/, built from extensions/ by scripts/sync-vendored.sh); this
// handler answers native messages out of the shared App Group:
//
// - `get-control-domain`: which Cabalmail server the containing mail app
//   is signed in to, so the user never types the control domain twice.
// - `resolve-private-link` / `forget-private-link`: the opaque-token form
//   of the private-link handoff (#1765). Safari has no `history` API, so
//   the redirector's fragment carries a token there and the target comes
//   through this bridge instead of through the URL. Resolution is
//   non-destructive -- a failed `windows.create` leaves the redirector tab
//   open and a reload must still resolve -- and the extension sends
//   `forget-private-link` once the private window is up.
//
// Unknown messages get an empty acknowledgement, matching the standalone
// host's handler. Both stores come from CabalmailShared, the one module
// this appex links (both Safari appexes compile this file).

import CabalmailShared
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        switch message?["kind"] as? String {
        case "get-control-domain":
            // JS expects `{ domain: string | null }`; NSNull crosses the
            // bridge as null.
            complete(context, [
                "domain": ExtensionControlDomainStore.read() as Any? ?? NSNull()
            ])
        case "resolve-private-link":
            // `{ url: string | null }`. An unknown or expired token is a
            // null, not an error: the extension then falls through to
            // leaving the redirector page up.
            let token = message?["token"] as? String
            let url = token.flatMap { PrivateLinkTokenStore.resolve($0) }
            complete(context, ["url": url as Any? ?? NSNull()])
        case "forget-private-link":
            if let token = message?["token"] as? String {
                PrivateLinkTokenStore.forget(token)
            }
            complete(context, ["ok": true])
        default:
            context.completeRequest(returningItems: nil)
        }
    }

    private func complete(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response])
    }
}
