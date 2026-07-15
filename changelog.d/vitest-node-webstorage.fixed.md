- **React test suite compatibility with Node 24+.** Node's experimental
  file-backed `localStorage` global shadowed jsdom's in the Vitest
  environment, failing every test that touches storage; the test runner now
  disables it (`--no-experimental-webstorage`). Also restored the intended
  single-fork serial test execution, which had been silently ignored since
  the Vitest 4 upgrade (`poolOptions.forks.singleFork` is now
  `fileParallelism: false`).
