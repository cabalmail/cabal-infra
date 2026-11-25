- **Compose 1.13 and Material 3 1.5 for the Android client.** Compose BOM
  2026.11.01, with AGP 9.5.2, KSP 2.3.14 and Gradle 9.9.2 from the same
  dependabot group. Compose 1.13 requires `compileSdk` 37.1, so both modules
  now compile against it; `targetSdk` and `minSdk` are unchanged. Material 3
  1.5 removed `MenuAnchorType` and made `ExposedDropdownMenu` an extension
  that has to be imported, so the six files with an exposed dropdown use
  `ExposedDropdownMenuAnchorType` and the new import. No behaviour change
  is intended.
