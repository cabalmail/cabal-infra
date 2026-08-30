// Flat config for the extensions workspace, kept close to
// react/admin/eslint.config.js in spirit: recommended rules, TypeScript via
// typescript-eslint, no per-project type-checking (kept fast for CI).
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: [
      '**/dist/**',
      '**/node_modules/**',
      'safari/Cabalmail.xcodeproj/**',
      'safari/build/**',
      // Build output of the web-extension bundle (gitignored).
      'safari/CabalmailExtension/Resources/**',
      // Captured fixture pages carry arbitrary third-party inline JS.
      'fixtures/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['scripts/**/*.mjs', '**/*.config.js', '**/*.config.ts'],
    languageOptions: {
      globals: { process: 'readonly', console: 'readonly' },
    },
  },
  {
    rules: {
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', caughtErrors: 'none', ignoreRestSiblings: true },
      ],
      // Discriminated-union narrowing reads better with explicit `kind`
      // switches; empty catch is the polyfill-recommended shape for
      // best-effort cleanup paths.
      'no-empty': ['error', { allowEmptyCatch: true }],
    },
  },
);
