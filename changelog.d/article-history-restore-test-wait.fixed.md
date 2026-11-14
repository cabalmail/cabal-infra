- **Flaky article back-and-forward tests.** `ArticleHistoryRestoreTests`
  went back and then toggled the reader as soon as the restored page read
  as on screen, but the article view's coordinator only then asks that page
  what it is, and its answer sets the toggle. On a loaded CI runner the
  toggle landed before the answer and was overwritten by it, so the page
  never changed and the next two waits ran out (#2430). The tests now wait
  for the coordinator's report of the restored page before going on, and a
  step whose wait runs out stops the test instead of failing the steps
  after it.
