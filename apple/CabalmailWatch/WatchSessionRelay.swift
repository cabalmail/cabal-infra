import CabalmailKit
import Foundation
import WatchConnectivity

/// WCSession delegate feeding `WatchAppModel`.
///
/// Lives in the app target rather than the Kit because WatchConnectivity is
/// the one dependency of the watch session that is genuinely platform-bound
/// — it has no macOS surface, so a Kit file importing it could not be
/// compiled by `swift test` (#1124). Everything the delegate decides is a
/// `WatchHandoff` decode, which the Kit already owns and tests.
///
/// Split out of the model for a second reason too: WCSession requires an
/// NSObject delegate and calls it on its own queue, so the relay decodes the
/// context off the main actor (`WatchHandoff` is Sendable, the raw context
/// dictionary is not) and hops to the model with the typed result.
@MainActor
final class WatchSessionRelay {
    /// Retains the WCSession delegate (the session holds it weakly).
    private var delegate: SessionDelegate?

    /// Arms the receiver for `model`. Idempotent, so the app's `.task` can
    /// call it across scene re-attaches.
    func activate(model: WatchAppModel) {
        guard WCSession.isSupported(), delegate == nil else { return }
        let delegate = SessionDelegate(model: model)
        self.delegate = delegate
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }
}

private final class SessionDelegate: NSObject, WCSessionDelegate {
    private weak var model: WatchAppModel?

    init(model: WatchAppModel) {
        self.model = model
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        // A context pushed while this app was dead is waiting on the
        // session rather than being redelivered through the delegate.
        let context = session.receivedApplicationContext
        guard !context.isEmpty else { return }
        dispatch(context)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        dispatch(context)
    }

    private func dispatch(_ context: [String: Any]) {
        if let handoff = WatchHandoff.from(applicationContext: context) {
            Task { @MainActor [weak model] in model?.apply(handoff) }
        } else if WatchHandoff.isSignedOut(applicationContext: context) {
            Task { @MainActor [weak model] in model?.clear() }
        }
        // Unknown version → ignore. An out-of-step phone app shouldn't
        // wipe a working watch session.
    }
}
