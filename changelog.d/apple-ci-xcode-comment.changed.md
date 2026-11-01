- **Apple CI's Xcode-selection comment no longer lists versions.** The
  `XCODE_VERSION` comment in `apple.yml` had fallen behind the `xcode-27`
  runner image: it still named 27.0 as the default and said `latest-stable`
  skips pre-release Xcodes, when it also picks release candidates. It now
  describes how the selection behaves, where a run's log records the image
  and Xcode it used, and which runner-images readme lists what is installed.
