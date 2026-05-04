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

export default defineConfig({
  plugins: [
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
    server: {
      deps: {
        inline: [/@tiptap\/.*/]
      }
    }
  }
});
