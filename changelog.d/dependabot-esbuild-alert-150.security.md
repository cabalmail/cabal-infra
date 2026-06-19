- Reviewed Dependabot alert #150 (esbuild withdrawn advisory GHSA). No code
  change applied: the advisory has been officially withdrawn from the GitHub
  Advisory Database, and the affected package is a transitive build-time
  dependency pinned by Vite 6.x to esbuild ^0.25.0. Remediating to esbuild
  >=0.28.1 requires a major Vite upgrade (v7 drops esbuild; v8 supports
  ^0.27.0 || ^0.28.0) which is tracked for a future release.
