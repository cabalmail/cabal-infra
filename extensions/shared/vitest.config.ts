import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      // The real polyfill throws when imported outside an extension
      // context; suites inject their own fakes for the APIs they exercise.
      'webextension-polyfill': fileURLToPath(
        new URL('./test/support/browser-stub.ts', import.meta.url),
      ),
    },
  },
  test: {
    // Node by default; DOM-touching suites opt in per-file with
    // `// @vitest-environment jsdom`.
    environment: 'node',
  },
});
