// Build orchestrator for the browser extension bundles: one TypeScript
// codebase (chrome/src + shared/), two manifests. Three Vite passes per
// browser -- background (ES module service worker), content script (IIFE:
// MV3 content scripts cannot be ES modules), popup (HTML entry) -- then the
// manifest is emitted from the per-browser template.
//
// Usage: node scripts/build-extension.mjs <chrome|safari>
// Env:
//   CABALMAIL_CONTROL_DOMAIN  control domain baked into the build
//                             (default cabalmail.example, a dev placeholder)
//   EXTENSION_VERSION         manifest version (default: latest CHANGELOG
//                             release, falling back to 0.0.1)

import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'vite';

const here = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(here, '..');
const repoRoot = resolve(workspaceRoot, '..');

const browser = process.argv[2];
if (browser !== 'chrome' && browser !== 'safari') {
  console.error('usage: build-extension.mjs <chrome|safari>');
  process.exit(2);
}

const controlDomain = process.env.CABALMAIL_CONTROL_DOMAIN || 'cabalmail.example';

function versionFromChangelog() {
  try {
    const changelog = readFileSync(join(repoRoot, 'CHANGELOG.md'), 'utf8');
    const match = changelog.match(/^## \[(\d+\.\d+\.\d+)\]/m);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}
const version = process.env.EXTENSION_VERSION || versionFromChangelog() || '0.0.1';

const srcRoot = join(workspaceRoot, 'chrome', 'src');
const outDir =
  browser === 'chrome'
    ? join(workspaceRoot, 'chrome', 'dist')
    : join(workspaceRoot, 'safari', 'CabalmailExtension', 'Resources');

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

const shared = {
  configFile: false,
  logLevel: 'warn',
  define: {
    __CONTROL_DOMAIN__: JSON.stringify(controlDomain),
  },
  esbuild: {
    jsx: 'automatic',
    jsxImportSource: 'preact',
  },
};

// Pass 1: background service worker (ES module).
await build({
  ...shared,
  build: {
    outDir,
    emptyOutDir: false,
    minify: false,
    lib: {
      entry: join(srcRoot, 'background.ts'),
      formats: ['es'],
      fileName: () => 'background.js',
    },
  },
});

// Pass 2: content script (single-file IIFE).
await build({
  ...shared,
  build: {
    outDir,
    emptyOutDir: false,
    minify: false,
    lib: {
      entry: join(srcRoot, 'content.ts'),
      formats: ['iife'],
      name: 'CabalmailContent',
      fileName: () => 'content.js',
    },
  },
});

// Pass 3: popup (HTML entry).
await build({
  ...shared,
  root: join(srcRoot, 'popup'),
  build: {
    outDir,
    emptyOutDir: false,
    minify: false,
    rollupOptions: {
      input: join(srcRoot, 'popup', 'popup.html'),
      output: {
        entryFileNames: 'popup.js',
        chunkFileNames: 'popup-[name].js',
        assetFileNames: '[name][extname]',
      },
    },
  },
});

// Manifest: per-browser template with build-time substitutions.
const template = readFileSync(
  join(workspaceRoot, browser, 'manifest.template.json'),
  'utf8',
);
const substituted = template
  .replaceAll('__CONTROL_DOMAIN__', controlDomain)
  .replaceAll('__VERSION__', version);
const manifest = JSON.parse(substituted); // fail the build on malformed output
// The `key` field pins the extension ID for unpacked dev builds, but the
// Chrome Web Store rejects any NEW-item upload that carries one ("key field
// not allowed in manifest") and assigns the listing its own ID instead.
// EXTENSION_STORE_BUILD=1 produces the store-uploadable variant.
if (process.env.EXTENSION_STORE_BUILD) {
  delete manifest.key;
}
writeFileSync(join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

console.log(`[build-extension] ${browser} v${version} -> ${outDir}`);
