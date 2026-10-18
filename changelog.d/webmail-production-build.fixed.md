- **Webmail ships React's production build.** The webmail on stage and
  prod was React's development build: `app.yml` set `NODE_ENV` to the
  environment's name (`prod`, `stage`, `development`) for the build,
  which Create React App ignored but Vite honours. So every deploy since
  the Vite migration shipped development React: about 485 KB instead of
  285 KB, with development-only checks running, and `StrictMode` running
  every mount effect twice. The build step no longer sets `NODE_ENV`,
  and `vite build` now fails on any `NODE_ENV` other than `production`
  instead of shipping a development build.
