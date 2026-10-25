- **visionOS app built from its own Xcode target.** `CabalmailVision` in
  `apple/project.yml` compiles the same `apple/Cabalmail/` sources for
  visionOS, with the same bundle identifier, entitlements and App Store
  profile as the iPhone/iPad target but none of its embedded targets (the
  watch app, the Notification Service Extension, the Safari web
  extension). The one target that served both platforms had to
  destination-filter those three embeds to iOS, and an embed phase present
  with every member filtered out made the `CodeSign` task depend on its own
  output: a second signed visionOS-simulator build into one DerivedData
  failed with `error: Cycle inside Cabalmail` and the directory never
  recovered. `apple.yml`'s visionOS build and upload legs now archive the
  new scheme.
