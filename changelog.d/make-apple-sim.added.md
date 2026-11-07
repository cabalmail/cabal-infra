- **`make apple-sim`: one-command simulator run.** `scripts/run-sim.sh`
  finds or creates a simulator of the requested device type (default
  iPhone Duo; `DEVICE=` picks another) on the newest iOS runtime that
  supports it, boots it, opens the simulator window (Simulator.app, or
  Xcode 27's DeviceHub), builds and installs a sign-in-capable app with
  `apple/scripts/build-sim.sh`, and launches it. The simulator is reused
  between runs, so its keychain and sign-in persist.
