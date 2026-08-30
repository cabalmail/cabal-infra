import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // Node by default; DOM-touching suites opt in per-file with
    // `// @vitest-environment jsdom`.
    environment: 'node',
  },
});
