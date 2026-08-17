- **Android CI/CD.** `lint.yml` gains a `kotlin` job running the Android
  client's quality gate (unit tests, ktlint, Android Lint with warnings
  promoted to errors) on every PR touching `android/**`; the new
  `android.yml` runs the same gate plus an unsigned release build on
  `stage`/`main` pushes, then uploads a signed bundle to the Play Console
  internal track via gradle-play-publisher, warn-green until the
  signing/Play secrets are seeded. Dependabot now also watches the Android
  version catalog.
