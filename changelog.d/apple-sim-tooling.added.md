- **Simulator build and drive tooling.** `apple/scripts/build-sim.sh`
  produces a sign-in-capable iOS simulator build with the non-obvious
  flags baked in, and `apple/Tools/SimDrive` adds an XCUITest-based
  command REPL that drives the installed app by accessibility
  identifier (tap, type, paste, swipe-reveal with hold, tree dump) from
  the host shell. Documented in `docs/apple.md` under "Simulator
  testing and automation".
