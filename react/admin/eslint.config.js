import js from '@eslint/js';
import react from 'eslint-plugin-react';
import reactHooks from 'eslint-plugin-react-hooks';
import globals from 'globals';

// Flat ESLint config for the admin app. Correctness-focused: the goal is to
// fail CI on real bugs (undeclared vars, broken hooks, unreachable code), not
// to enforce a style. Stylistic and convention rules that the existing
// codebase does not follow are left off rather than mass-rewritten.
//
// The app is a Vite + React 18 SPA using the automatic JSX runtime, so JSX
// files do not have to import React (react/react-in-jsx-scope is off via the
// jsx-runtime config). prop-types are not used anywhere in this codebase, so
// react/prop-types is off too.
export default [
  {
    ignores: ['dist/**', 'public/**', 'coverage/**', 'node_modules/**'],
  },
  js.configs.recommended,
  react.configs.flat.recommended,
  react.configs.flat['jsx-runtime'],
  reactHooks.configs['recommended-latest'],
  {
    files: ['**/*.{js,jsx}'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      globals: {
        ...globals.browser,
        ...globals.es2021,
      },
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
    },
    settings: {
      react: { version: 'detect' },
    },
    rules: {
      // The codebase passes props through without declaring prop-types.
      'react/prop-types': 'off',
      // Apostrophes and quotes in JSX text are fine; this rule is HTML-entity
      // pedantry, not a correctness check.
      'react/no-unescaped-entities': 'off',
      // Keep dead-code detection on, but tolerate the idioms the codebase
      // relies on: a top-level `import React` left in place under the
      // automatic JSX runtime; unused `catch (e)` and `_`-prefixed args; and
      // destructuring-with-rest used to omit fields (e.g. stripping secrets
      // before persisting via `const { password, ...safe } = state`).
      'no-unused-vars': ['error', {
        varsIgnorePattern: '^React$',
        argsIgnorePattern: '^_',
        caughtErrors: 'none',
        ignoreRestSiblings: true,
      }],
      // Irregular whitespace in code is a bug; in comments it is sometimes
      // deliberate (one comment documents a literal zero-width space).
      'no-irregular-whitespace': ['error', { skipComments: true }],
    },
  },
  {
    // Vitest runs with globals: true (see vite.config.js), so test files use
    // describe / it / expect / vi without importing them.
    files: ['**/*.test.{js,jsx}', 'src/test/**'],
    languageOptions: {
      globals: {
        ...globals.node,
        describe: 'readonly',
        it: 'readonly',
        test: 'readonly',
        expect: 'readonly',
        vi: 'readonly',
        beforeAll: 'readonly',
        afterAll: 'readonly',
        beforeEach: 'readonly',
        afterEach: 'readonly',
      },
    },
  },
  {
    // Config / build tooling files run under Node, not the browser.
    files: ['*.config.js'],
    languageOptions: {
      globals: { ...globals.node },
    },
  },
];
