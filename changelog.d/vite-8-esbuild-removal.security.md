- The admin React app now builds with Vite 8 (up from Vite 6), which
  bundles via rolldown rather than esbuild and drops the transitive
  `esbuild` package from the dependency tree entirely, resolving Dependabot
  alert #150 (esbuild `< 0.28.1` remote-code-execution advisory). No Vite
  6.x or 7.x release could reach the patched esbuild line. `@vitejs/plugin-react`
  was bumped to 6.x to match; the build now requires Node `^20.19 || >=22.12`.
