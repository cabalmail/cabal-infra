import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import license from 'rollup-plugin-license';
import { copyFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_LICENSE = path.resolve(__dirname, '../../LICENSE.md');
const PUBLIC_LICENSE = path.resolve(__dirname, 'public/LICENSE.md');
const NOTICES_FILE = path.resolve(__dirname, 'dist/third-party-notices.txt');

// Copy the canonical AGPL-3.0 LICENSE.md from the repo root into public/
// so it ships as a static asset and the About page can fetch /LICENSE.md
// in both dev and production. Source of truth remains the root file.
function copyRepoLicense() {
  return {
    name: 'cabalmail:copy-license',
    buildStart() {
      try {
        mkdirSync(path.dirname(PUBLIC_LICENSE), { recursive: true });
        copyFileSync(REPO_LICENSE, PUBLIC_LICENSE);
      } catch (e) {
        this.warn(`Could not copy LICENSE.md: ${e.message}`);
      }
    },
  };
}

// React picks its production build only when NODE_ENV is `production`, and
// vite build honours a NODE_ENV it finds in the environment, so a build run
// with NODE_ENV set to anything else ships React's development build: twice
// the size, with development-only checks and StrictMode running every mount
// effect twice. app.yml did exactly that for years by setting NODE_ENV to the
// environment's name (#2115). Fail such a build rather than ship it.
function refuseDevelopmentReactBuild() {
  return {
    name: 'cabalmail:refuse-development-react-build',
    config(_config, { command }) {
      const nodeEnv = process.env.NODE_ENV;
      if (command === 'build' && nodeEnv && nodeEnv !== 'production') {
        throw new Error(
          `NODE_ENV=${nodeEnv} would make vite build ship React's development build. `
          + 'Unset NODE_ENV, or set it to production, to build the webmail.'
        );
      }
    },
  };
}

export default defineConfig({
  plugins: [
    refuseDevelopmentReactBuild(),
    copyRepoLicense(),
    react(),
    license({
      thirdParty: {
        includePrivate: false,
        output: {
          file: NOTICES_FILE,
        },
      },
    }),
  ],
  server: {
    port: 3000,
    open: true
  },
  build: {
    outDir: 'dist'
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/test/setup.js',
    // Run test files serially in a single forked process. jsdom is heavy
    // and the default parallel worker pool was driving RSS into multi-GB
    // territory on this suite. Trades wall-clock for memory ceiling.
    // (Vitest 4 spelling; replaces the v3 poolOptions.forks.singleFork.)
    pool: 'forks',
    fileParallelism: false,
    // Node 24+ exposes its own experimental file-backed `localStorage` global
    // by default; without --localstorage-file it is a getter that returns
    // undefined, and it shadows jsdom's localStorage in the test environment
    // (every window.localStorage access sees undefined). Disable it so
    // jsdom's implementation wins regardless of Node version.
    execArgv: ['--no-experimental-webstorage'],
    server: {
      deps: {
        inline: [/@tiptap\/.*/]
      }
    }
  }
});
