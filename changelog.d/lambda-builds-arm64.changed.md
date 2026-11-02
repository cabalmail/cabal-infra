- **Lambda zips build on arm64 runners.** `app.yml`'s `lambda-api` and
  `lambda-counter` jobs moved from `ubuntu-latest` to `ubuntu-24.04-arm`,
  matching the arm64 functions they build, so a dependency with compiled
  code installs the wheels for the processor that runs it. Every current
  dependency is pure Python, so today's zips are unchanged. `fetch_bimi`,
  the one x86_64 function, now fails its build if its dependencies include
  compiled code.
