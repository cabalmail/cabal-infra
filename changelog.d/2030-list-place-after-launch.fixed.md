- Apple: **A folder picked after launch keeps its place.** The message
  list's landing stood itself down whenever the view's load task had been
  cancelled, which on a compact folder pick is every time: the list is
  mounted twice, so the load that lands it reports back through the first
  mount's cancelled task while the list on screen is the second mount's.
  A list that never lands records nothing as it scrolls, so a relaunch
  reopened such a folder at the top while the folder the app launched on
  came back exactly where it was. The landing now stands down only while
  the list is off screen, and is made when the list comes back.
