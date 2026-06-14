# Known Vulnerabilities Requiring Manual Attention

This file tracks Dependabot alerts that cannot be resolved automatically
because the safe fix path requires a breaking dependency upgrade.

---

## esbuild < 0.28.1 (Dependabot Alert #150)

**Severity:** High  
**CVE:** N/A (GitHub Advisory GHSA)  
**Description:** Missing binary integrity verification in esbuild's Deno module
enables remote code execution when `NPM_CONFIG_REGISTRY` is set to a malicious
registry.

**Note on practical impact:** The vulnerability is in esbuild's Deno-specific
install path. This project uses esbuild only via Node.js (through Vite). The
attack vector requires using esbuild from Deno with a tampered
`NPM_CONFIG_REGISTRY`, which does not apply to this project's build pipeline.
The risk is low but the alert is valid and should be resolved.

**Current state:**  
- Installed: `esbuild@0.25.12` (transitive dependency of `vite@6.4.2`)  
- Required: `esbuild >= 0.28.1`

**Why automated fix failed:**  
`vite@6.4.2` constrains esbuild to `^0.25.0`. Forcing esbuild to `0.28.1` via
`package.json` `overrides` breaks the Vite build:

```
Transforming destructuring to the configured target environment
("chrome87", "edge88", "es2020", "firefox78", "safari14" + 2 overrides)
is not supported yet
```

This is a breaking change introduced in esbuild 0.26+: support for
transforming destructuring assignments to very old browser targets was removed.
Vite 6.x targets these browser versions by default.

All Vite 6.x versions and all Vite 7.x versions pin esbuild to `^0.25.0` or
`^0.27.0`. Vite 8.0 dropped esbuild entirely (switched to rolldown) but is a
major breaking change with its own upgrade risk.

**Recommended manual action:**  
Upgrade Vite to 8.x and update the `vite.config.js` to remove browser targets
that esbuild 0.28.x no longer supports, or adjust the `build.target` config to
a version that esbuild 0.28.x does support. This will require:

1. `npm install --save-dev vite@^8.0.16`
2. Verify `react/admin/vite.config.js` (check `build.target`, plugin compat)
3. Run `npm run build` and `npm run test` to validate
4. Update `@vitejs/plugin-react` to a version compatible with Vite 8

**Tracked:** 2026-06-14 (Dependabot alert #150)
