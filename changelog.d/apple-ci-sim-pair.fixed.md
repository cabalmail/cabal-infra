- **Apple CI simulator setup survives device-specific runtimes.** The
  simulator test jobs chose the newest iOS runtime and the first iPhone device
  type separately, so on the 2026-10-22 runner image, which preinstalls an
  iOS 27.1 runtime that supports only the iPhone Duo, `simctl create` refused
  the pair before any build ran. Both resolvers now share
  `.github/scripts/resolve-sim-destination.sh`, which takes the device type
  first and pairs it with the newest runtime that lists it as supported (so
  iPhone 18 Pro on iOS 27.0 today), and logs the pair before creating the
  device. `scripts/tests/test_select_sim_pair.py` pins the choice against
  fixtures of that image.
