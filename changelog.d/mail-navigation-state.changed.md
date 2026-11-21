- **A window's place in mail is a value type of its own.** The sidebar's
  folder, the open message, the collapsed split's column and the tree
  that owns them sat in `SceneNavigator`'s class body, which had reached
  SwiftLint's 250-line cap, so the next member added to it failed CI.
  They move into `MailNavigationState`, built like
  `FeedNavigationState`: each transition changes the place and returns
  what follows from it, and the navigator applies that to the route, the
  resume session, the folder list's hold and the tab. The navigator's
  body drops from 250 to 187 counted lines. Every fold, narrow, widen
  and launch behaves as before, and every navigator test passes
  unchanged. `MailNavigationStateTests` covers each transition and the
  tree gate; `SceneNavigatorMailPlaceTests` holds that a write which
  changes nothing redraws nothing.
