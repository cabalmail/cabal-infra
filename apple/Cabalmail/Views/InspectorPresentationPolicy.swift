import Foundation

/// Who may open the addresses inspector: the `@` button, and only it.
///
/// `.inspector(isPresented:)` hands its binding to the framework, which
/// writes back what it believes the presentation state is. On an iPhone Duo
/// that belief is wrong in one case: the regular split built by unfolding
/// while a message is open receives a `true` about 200 ms after it appears,
/// with no tap anywhere (measured on the iOS 27.1 beta simulator, #1663).
/// Sometimes the address column then takes the right-hand page unasked and
/// cannot be dismissed; sometimes the column stays hidden but the split lays
/// out as if it were there, and the message list overlaps the reading pane
/// (#1665). Either way the state has drifted from anything the user did.
///
/// The rule: a request to present is honoured only while the button has
/// asked for it; a request to dismiss is always honoured, so a system
/// dismissal (a drag, a size change) still clears the state. A pure rule
/// rather than an inline `if` so it can be tested — `MailRootView`'s
/// `@State` isn't reachable from a unit test, this is.
enum InspectorPresentationPolicy {
    struct State: Equatable {
        /// What `.inspector(isPresented:)` is bound to.
        var presented: Bool
        /// Whether the `@` button asked for the current presentation.
        var requested: Bool
    }

    /// The button was tapped: toggle, and mark the result as requested.
    static func toggled(_ state: State) -> State {
        let next = !state.presented
        return State(presented: next, requested: next)
    }

    /// The framework wrote `incoming` into the binding.
    static func framework(wrote incoming: Bool, to state: State) -> State {
        if incoming {
            // Only the button opens the inspector.
            return state.requested ? State(presented: true, requested: true) : state
        }
        return State(presented: false, requested: false)
    }
}
