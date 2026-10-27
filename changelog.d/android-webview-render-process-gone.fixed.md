- Android: **No crash when a web view's renderer dies.** When Android
  ended the render process behind the mail reader or the feed article
  view, to reclaim memory or because the page crashed it, the whole app
  went down with it. Both views now claim `onRenderProcessGone`
  (`RendererRecovery`): a reclaimed renderer is replaced by a fresh view
  that reloads the document, a crashed one gets one silent reload, and a
  second crash on the same document shows a notice with Retry instead of
  reloading in a loop. The mail reader's WebView is now destroyed when it
  leaves the screen, as the article view's already was. androidx.webkit
  1.18's Lint check (`MissingOnRenderProcessGone`) flagged both.
