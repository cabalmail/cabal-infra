- **Android CI/CD (`android.yml`).** Unit tests, ktlint, and Android Lint
  (warnings promoted to errors) plus an unsigned release build on every PR
  touching `android/**`; pushes to `stage`/`main` additionally build a
  signed bundle and upload it to the Play Console internal track via
  gradle-play-publisher, warn-green until the signing/Play secrets are
  seeded. Dependabot now also watches the Android version catalog.
