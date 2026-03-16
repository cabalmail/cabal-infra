# React Modernization Plan

## Context

The React email client in `react/admin/` is built on React 17 with Create React App (deprecated), 100% class-based components, no state management beyond prop drilling, an abandoned WYSIWYG editor (draft-js), and zero test coverage. This plan modernizes the codebase in phases, each leaving the app fully functional.

---

## Current State Summary

| Issue | Detail |
|-------|--------|
| React version | 17.0.2 (current: 18.x) |
| Build tool | CRA / react-scripts 5.0.0 (deprecated) |
| Components | 20+ class-based, 1 functional |
| State mgmt | setState + prop drilling 5 levels deep |
| WYSIWYG | draft-js (abandoned by Meta) + 4 companion packages |
| Tests | 0 (libraries installed, unused) |
| CSS | Global per-component CSS files |
| Bugs | `this.stage` typo, memory leak risk in timers, race conditions in pagination |
| Security | JWT + password persisted to localStorage via setState override |
| Unused deps | react-lazyload, react-docgen |
| CI workflow | Uses `yarn` (not installed locally), `react-docgen` for docs, CRA-specific flags |

---

## Phase 1: Build Tooling & Dependency Updates

**Risk: Low**

1. **Migrate CRA to Vite**
   - Install `vite`, `@vitejs/plugin-react`; create `vite.config.js`
   - Move `public/index.html` to root, add module script tag
   - Update `package.json` scripts (`vite`, `vite build`, `vitest`)
   - Remove `react-scripts`, `eslintConfig`, `browserslist` from `package.json`
   - Replace test runner with `vitest` + `jsdom`

2. **Fix package management** -- delete `yarn.lock`, regenerate `package-lock.json`

3. **Update safe deps** -- `axios` 0.24 -> 1.x, `dompurify` 2.x -> 3.x, `react-intersection-observer` and `react-swipeable-list` to latest

4. **Remove unused deps** -- `react-lazyload`, `react-docgen`

5. **Update CI workflow** (`.github/workflows/react.yml`)
   - Build job: `yarn install && yarn build --profile` -> `npm ci && npm run build`
   - Vite outputs to `dist/` not `build/` -- update `tar` command and S3 sync path
   - Update path triggers: add `react/admin/index.html` (moved from `public/`), add `react/admin/vite.config.js`
   - Pin `actions/checkout@main` to a version tag (e.g., `@v4`) for reproducibility
   - Remove or rework the `document` job -- `react-docgen` doesn't work well with functional components/hooks. Options: (a) replace with a lighter tool like `react-docgen-typescript` later if TypeScript is added, (b) use Storybook for component docs, or (c) drop auto-generated docs for now. Recommend (c) since the docs job's props section is already commented out and the codebase is small.
   - Documentation script (`.github/scripts/react-documentation.sh`) also uses `yarn install` -- update or remove alongside the `document` job

**Files:** `package.json`, new `vite.config.js`, `index.html` (moved), `src/index.js`, `.github/workflows/react.yml`, `.github/scripts/react-documentation.sh`
**Verify:** `npm run dev`, `npm run build`, login + browse email manually, push to a branch and verify CI passes

---

## Phase 2: Context API & Leaf Component Conversion

**Risk: Low-Medium**

1. **Create `src/contexts/AuthContext.js`**
   - Provides: `token`, `api_url`, `host`, `domains`, `imap_host`
   - `useAuth()` hook

2. **Create `src/contexts/AppMessageContext.js`**
   - Provides: `setMessage` function
   - `useAppMessage()` hook

3. **Create `src/hooks/useApi.js`**
   - Pulls auth from context, returns ApiClient instance
   - Eliminates `new ApiClient(this.props.api_url, this.props.token, this.props.host)` repeated in 7 components

4. **Fix App.js `setState` override** (lines 61-68) -- currently serializes entire state including `password` to localStorage. Replace with selective persistence of safe fields only.

5. **Fix `this.stage` typo** in `MessageOverlay/index.js:155`

6. **Convert leaf components to functional:**
   - `AppMessage/index.js` -- stateless display
   - `Nav/index.js` -- stateless display; also fix `<a>` -> `<button>` for accessibility
   - `Login/index.js` -- form component
   - `SignUp/index.js` -- form component

7. **Write tests** for converted components with `@testing-library/react`

**New files:** `src/contexts/AuthContext.js`, `src/contexts/AppMessageContext.js`, `src/hooks/useApi.js`
**Modified:** `App.js`, `AppMessage/index.js`, `Nav/index.js`, `Login/index.js`, `SignUp/index.js`, `MessageOverlay/index.js`

---

## Phase 3: Core Email Component Conversion

**Risk: Medium** (Messages.js polling is the hardest conversion)

1. **Convert `Email/index.js`** -- `useState` for folder/overlay state, consume `useAuth()` and `useAppMessage()`

2. **Convert `Messages/index.js`** (most complex)
   - Move 5 timer IDs (`callbackTimeout`, `poller1Timeout`, `poller2Timeout`, `archiveTimeout`, `interval`) into a single `useEffect` with proper cleanup
   - Use `useRef` for timer IDs
   - Polling closure captures state naturally, eliminating the `that` parameter pattern

3. **Convert `Envelopes.js`**
   - Fix race condition: multiple async `getEnvelopes` calls overwrite `this.state.pages`
   - Use functional state updates (`setPages(prev => ...)`) to prevent data loss
   - Replace `arrayCompare` + `componentDidUpdate` with `useEffect` on `message_ids`

4. **Convert `Envelope.js`, `Messages/Folders/index.js`, `Actions/index.js`** -- straightforward

5. **Write tests** for polling behavior (mock timers) and envelope pagination

**Modified:** `Email/index.js`, `Messages/index.js`, `Envelopes.js`, `Envelope.js`, `Messages/Folders/index.js`, `Email/Actions/index.js`

---

## Phase 4: Replace draft-js & Convert Remaining Components

**Risk: Medium-High** (editor replacement is the single biggest change)

1. **Replace draft-js with TipTap in `ComposeOverlay/index.js`**
   - Install: `@tiptap/react`, `@tiptap/starter-kit`, `@tiptap/extension-link`, `@tiptap/extension-color`, `@tiptap/extension-text-style`, `@tiptap/extension-text-align`
   - Remove 5 packages: `draft-js`, `react-draft-wysiwyg`, `draftjs-to-html`, `html-to-draftjs`, `markdown-draft-js`
   - TipTap works natively with HTML, simplifying the conversion:
     - Load: `editor.commands.setContent(htmlBody)` replaces `htmlToDraft` + `ContentState` chain
     - Save: `editor.getHTML()` replaces `draftToHtml(convertToRaw(...))`
   - Build toolbar matching current options (formatting, lists, alignment, color, links, emoji)

2. **Convert `ComposeOverlay/index.js` to functional** (~488 lines)

3. **Convert `MessageOverlay/index.js`** -- fix sequential `setState` calls that can overwrite each other (lines 43-97)

4. **Convert `RichMessage.js`** -- use `useRef` for DOM access instead of `document.getElementById`

5. **Convert `Addresses/index.js`, `Addresses/List.js`, `Addresses/Request.js`, `Folders/index.js`**

6. **Write tests** for compose flow and message overlay

**Verify:** Compose (new, reply, reply-all, forward), HTML rendering in replies, send flow

---

## Phase 5: Cleanup & Hardening

**Risk: Low**

1. **Add Error Boundaries** -- wrap Email, Addresses, Folders views with fallback UI

2. **Code splitting** -- `React.lazy` + `Suspense` for view components and ComposeOverlay (TipTap bundle)

3. **Upgrade React 17 -> 18**
   - `ReactDOM.render` -> `createRoot`
   - Update `react`, `react-dom`, `@testing-library/react`
   - Enable Strict Mode to surface cleanup issues
   - Do NOT jump to 19 yet (breaking changes around refs/context)

4. **CSS Modules migration** -- rename `.css` -> `.module.css`, update imports to `styles.className` pattern (Vite supports natively; can coexist with global CSS during migration)

5. **Security: Move JWT from localStorage to memory** -- store token in ref/module variable, rely on Cognito session refresh on reload

---

## Future Considerations (Out of Scope)

- TypeScript -- add incrementally file-by-file after Phase 5
- React 19 -- wait for ecosystem maturity
- WebSocket for real-time updates -- replaces 10s polling but requires backend changes
- PWA / Service Worker -- re-add via Vite PWA plugin

## Critical Files

| File | Why |
|------|-----|
| `src/App.js` | Root: auth state, view routing, localStorage override |
| `src/Email/Messages/index.js` | Hardest conversion: 5 timers, polling, memory leak risk |
| `src/Email/ComposeOverlay/index.js` | draft-js integration point for 5 packages |
| `src/ApiClient.js` | Instantiated in 7 components; becomes hook-based |
| `src/Email/Messages/Envelopes.js` | Race condition in async pagination |
| `.github/workflows/react.yml` | CI: uses yarn, CRA flags, react-docgen; all change in Phase 1 |
| `.github/scripts/react-documentation.sh` | Uses react-docgen + yarn; remove or replace in Phase 1 |
