- Apple: **Requests hand back their background time.** On iPhone, iPad
  and Vision Pro, each request to the server asked iOS for extra time to
  finish in case the app went to the background, and never handed that
  time back. Once the app was in the background and the time ran out,
  iOS could end the app, so it started over when you came back to it.
  Each request now hands the time back as soon as it finishes.
