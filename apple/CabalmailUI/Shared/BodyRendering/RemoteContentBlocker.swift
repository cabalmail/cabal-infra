import Foundation
@preconcurrency import WebKit

/// The rule list the reader installs while remote content is off: it blocks
/// every `http`/`https` load, which is what stops tracker pixels and remote
/// CSS, fonts and iframes (`HTMLBodyCoordinator.render` adds and removes it).
/// Compilation is async and slightly expensive, so it happens once per
/// process and every message re-uses the result.
@MainActor
enum RemoteContentBlocker {
    /// The compiled list, once a compile has succeeded. `render` installs it
    /// synchronously when it is here, so a message never waits on a compile
    /// that already happened.
    private(set) static var cached: WKContentRuleList?
    private static var pendingCompile: Task<WKContentRuleList?, Never>?

    /// The compiled list, compiling it on first use. Callers that arrive
    /// while a compile is running share it. Nil when compilation failed.
    static func shared() async -> WKContentRuleList? {
        if let cached { return cached }
        if let pendingCompile { return await pendingCompile.value }
        let task = Task<WKContentRuleList?, Never> { @MainActor in
            let json = """
            [
              {
                "trigger": { "url-filter": "^https?://" },
                "action": { "type": "block" }
              }
            ]
            """
            do {
                let list = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "cabalmail-block-remote",
                    encodedContentRuleList: json
                )
                cached = list
                return list
            } catch {
                return nil
            }
        }
        pendingCompile = task
        let list = await task.value
        pendingCompile = nil
        return list
    }
}
