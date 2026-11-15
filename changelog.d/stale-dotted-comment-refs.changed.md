- **Two Apple-client test comments now name the type that owns the member.**
  The mail-event search suite credited the search model to
  `AppState.sharedSearchModel` and called it process-wide, fourteen minutes
  before that model moved to `SceneNavigator` as one per window; the
  session-wiring suite credited `wireSession` to `AppState`, which handed it to
  `SessionManager` two days later, and still described that move as pending.
  Comments only, no code change.
