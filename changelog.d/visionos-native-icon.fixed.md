- **Native visionOS build and icon restored.** The visionOS target had not
  compiled since the sidebar-branding change (`sharedBackgroundVisibility` is
  compile-time unavailable on visionOS, which a runtime `#available` check
  cannot gate), and the hardcoded `CFBundleIconName: AppIcon` pointed visionOS
  at the flat iOS icon instead of the layered `AppIconVision` stack. The
  toolbar mark now takes the plain path on visionOS, and `CFBundleIconName`
  is routed through `ASSETCATALOG_COMPILER_APPICON_NAME` so each platform
  resolves its own icon.
