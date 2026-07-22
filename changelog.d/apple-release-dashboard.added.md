- **Apple release dashboard (`scripts/apple-dashboard-app.py`).** A local
  Flask app - with data engine `scripts/apple-release-dashboard.py` - that
  tracks each Apple `changelog.d` entry through the stage, prod, and beta
  TestFlight groups. It recovers from git when an entry landed on `stage`,
  resolves the first build carrying it in each lane (and whether a build
  exists at all before App Store Connect attaches it to a group),
  dereferences marketing and build (`CFBundleVersion`) versions, and reads
  each build's App Store Connect status. Tracks the branch from
  `origin/stage`, and can attach a build to a TestFlight group from the
  build ledger.
