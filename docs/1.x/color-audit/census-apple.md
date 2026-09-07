# Apple clients: chromatic colour census

Repo: `/Users/claude/cabal-infra/.claude/worktrees/bridge-cse_01Con3QNK9tPEED7HWDNv4yC` (worktree, read-only). Scope: `apple/Cabalmail`, `apple/CabalmailMac`, `apple/CabalmailWatch`, `apple/CabalmailKit/Sources`, `apple/*/Assets.xcassets`. Test targets excluded. All paths below are relative to `apple/`.

Method: `grep -rnE` over the scope with an alternation of SwiftUI named colours, `Color(...)` constructors, `UIColor`/`NSColor` system colours, `.tint`/`.accentColor`/`.foregroundStyle`/`.fill`/`.background`/`.stroke`/`.shadow`, gradients, `*Tint` types, palette/swatch names, and CSS colour literals; every hit opened and read. A second catch-all `Color(`/`Color.` sweep found nothing beyond the first pass. Platform-neutral greys (`.primary`, `.secondary`, `.quaternary`, `.clear`, `.black`, `.white`, `Color.secondary.opacity(...)`) are listed only where they sit on the same site as a chromatic colour.

Note on `.foregroundStyle(.tint)`: the environment tint resolves to the `AccentColor` asset (brand forest green) on iOS/watchOS, but macOS substitutes the user's System Settings accent unless that is "multicolor". Those sites are listed as `accent` / `platform-adaptive`. `Color("AccentColor")` (pinned asset) is listed as `asset-catalog`.

Note on `Button(role: .destructive)`: 29 sites let the platform pick the destructive red; none of them chooses a colour, so they are not tabulated.

## Cabalmail (iOS / iPadOS / visionOS app target; `Cabalmail/Views` is also compiled into CabalmailMac)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| Cabalmail/ContentView.swift:44 | `.foregroundStyle(Color("LogoTint"))` on `Image("CabalmailMark")` (132pt, restoring splash) | glyph-fg | brand/logo | system background (white / dark surface) | asset-catalog | no |
| Cabalmail/Views/SidebarBranding.swift:46 | `Swatch(light: 0x286CAB, dark: 0x79BDFF) // azure` | wash | address-swatch (decorative sidebar wash) | sidebar material | scheme-aware (`colorScheme` branch at :82) | no |
| Cabalmail/Views/SidebarBranding.swift:51 | `Swatch(light: 0xA16100, dark: 0xFAB45F) // amber` | wash | address-swatch (decorative) | sidebar material | scheme-aware | no |
| Cabalmail/Views/SidebarBranding.swift:56 | `Swatch(light: 0x2B633A, dark: 0x79C289) // forest` | wash | address-swatch / brand (same values as AccentColor) | sidebar material | scheme-aware | no |
| Cabalmail/Views/SidebarBranding.swift:61 | `Swatch(light: 0x793974, dark: 0xE39BDC) // plum` | wash | address-swatch (decorative) | sidebar material | scheme-aware | no |
| Cabalmail/Views/SidebarBranding.swift:75 | `.opacity(0.20)` on the whole `SidebarWash` ZStack | wash | decorative (fixed 20% wash) | sidebar material | fixed | no |
| Cabalmail/Views/SidebarBranding.swift:83-86 | `EllipticalGradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0), location: 0.7)])` per blob | wash (gradient) | decorative | sidebar material | scheme-aware (`color` picked at :82) | no |
| Cabalmail/Views/SidebarBranding.swift:108-114 | `Color.init(rgb: UInt32)` -> `Color(.sRGB, red:green:blue:)` | wash (constructor for the four swatches) | address-swatch | n/a | fixed per value | no |
| Cabalmail/Views/SidebarBranding.swift:135 | `.foregroundStyle(Color("LogoTint"))` on `CabalmailMark` (90/102/132pt) | glyph-fg | brand/logo | sidebar (over the swatch wash + material) | asset-catalog | no |
| Cabalmail/Views/SignInView.swift:118 | `Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)` | text-fg + glyph-fg | error-state (sign-in) | white form row (grouped form on macOS) | platform-adaptive (systemRed) | no |
| Cabalmail/Views/SignInView.swift:199 | `Label(mfaError, ...).foregroundStyle(.red)` | text-fg + glyph-fg | error-state (MFA) | white form row | platform-adaptive | no |
| Cabalmail/Views/SignInView.swift:302 | `.foregroundStyle(Color("LogoTint"))` on `Image("CabalmailMark")` 96pt (`MacSignInChrome`) | glyph-fg | brand/logo | macOS window background | asset-catalog | no |
| Cabalmail/Views/MessageListView+Rows.swift:307 | `SwipeActionSpec(... "Delete Forever", tint: .red, role: .destructive)` | control-tint | danger/destructive (purge) | swipe action (revealed) | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:320 | `SwipeActionSpec(... "Restore", tint: .blue)` | control-tint | other (restore to inbox; deliberately non-destructive) | swipe action | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:329 | `SwipeActionSpec(... Archive/Trash, tint: .red, role: .destructive)` | control-tint | danger/destructive (dispose) | swipe action | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:345 | `SwipeActionSpec(... Read/Unread, tint: .blue)` | control-tint | unread (toggle `\Seen`) | swipe action | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:405 | `.foregroundStyle(isChecked ? Color.accentColor : Color.secondary)` (bulk checkmark) | glyph-fg | selected (bulk mode) | plain list row / accent 0.15 selection wash | platform-adaptive (accent) | no |
| Cabalmail/Views/MessageListView+Rows.swift:410 + :503 | `Circle().fill(unreadDotColor)`; `unreadDotColor = flags.contains(.seen) ? .clear : Color("AccentColor")` | fill (8pt dot) | unread | plain list row / accent 0.15 selection wash | asset-catalog (pinned, see comment :497-501) | no |
| Cabalmail/Views/MessageListView+Rows.swift:442 | `Image("exclamationmark.shield.fill").foregroundStyle(.orange)` | glyph-fg | auth-bad (authentication warning) | plain list row | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:461 | `Image("exclamationmark.circle.fill").foregroundStyle(.red)` | glyph-fg | other (high importance) | plain list row | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:467 | `Image("flag.fill").foregroundStyle(.orange)` | glyph-fg | flagged (`\Flagged`) | plain list row | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Rows.swift:475-476 | `Circle().fill(FlagPaletteColor.color(for: paletteEntry(for: slot)?.color ?? ""))` (up to 4 dots, 8pt) | fill + user-data | user-flag-colour (deleted entry -> gray) | plain list row | platform-adaptive (system named colours) | no |
| Cabalmail/Views/RecipientFieldWithSuggestions.swift:68 | `.foregroundStyle(Color.accentColor.opacity(pickerAffordance.tintOpacity))` (1 or 0.35, see ContactsPickerAffordance.swift:52) | glyph-fg (control) | accent (contacts picker button; dimmed when inert) | compose form row (white / grouped) | platform-adaptive | no |
| Cabalmail/Views/AuthResultsLine.swift:29 | `Label(warningCopy, systemImage: "exclamationmark.shield.fill").foregroundStyle(.orange)` | text-fg + glyph-fg | auth-bad | reader header (plain surface) | platform-adaptive | no |
| Cabalmail/Views/AuthResultsLine.swift:57-58 | `.foregroundStyle(color(for: token)).background(color(for: token).opacity(0.12), in: Capsule())` (SPF/DKIM/DMARC chips) | on-fill + wash | auth-bad / success / neutral | the same colour's 0.12 wash over reader header | platform-adaptive | no |
| Cabalmail/Views/AuthResultsLine.swift:65 | `case .ok: return .green` | user-data (verdict -> colour) | success (auth pass) | chip wash | platform-adaptive | no |
| Cabalmail/Views/AuthResultsLine.swift:66 | `case .bad: return .orange` | user-data | auth-bad | chip wash | platform-adaptive | no |
| Cabalmail/Views/ComposeView.swift:511 | `Label(errorMessage, ...).font(.callout).foregroundStyle(.red)` (pinned banner) | text-fg + glyph-fg | error-state (compose save/send) | `.bar` material | platform-adaptive | no |
| Cabalmail/Views/ComposeView.swift:618 | `Label(errorMessage, ...).foregroundStyle(.red)` (macOS strip) | text-fg + glyph-fg | error-state | compose window background | platform-adaptive | no |
| Cabalmail/Views/RichTextToolbar.swift:156 | `.background(isOn ? Color.accentColor.opacity(0.2) : .clear)` (icon toggle) | wash | selected (format toggle on) | toolbar | platform-adaptive | no |
| Cabalmail/Views/RichTextToolbar.swift:175 | `.background(isOn ? Color.accentColor.opacity(0.2) : .clear)` (text toggle) | wash | selected | toolbar | platform-adaptive | no |
| Cabalmail/Views/AddressListView.swift:64 | `Label(errorMessage, ...).foregroundStyle(.red)` | text-fg + glyph-fg | error-state | plain list row / sidebar | platform-adaptive | no |
| Cabalmail/Views/AddressListView.swift:293 | `suspendToggleButton(...).tint(.orange)` (leading swipe, full-swipe action) | control-tint | warning (suspend / reinstate) | swipe action | platform-adaptive | no |
| Cabalmail/Views/AddressListView.swift:310 | `.tint(address.favorite ? .gray : .yellow)` (trailing swipe) | control-tint | flagged (favorite / unfavorite) | swipe action | platform-adaptive | no |
| Cabalmail/Views/AddressListView.swift:359 | `Image(favorite ? "star.fill" : "at").foregroundStyle(address.favorite ? Color.yellow : Color("AccentColor"))` | glyph-fg | flagged (favorite) / accent (address icon) | plain list row / sidebar | platform-adaptive (yellow) / asset-catalog (accent, pinned per comment :355-358) | no |
| Cabalmail/Views/AddressListView.swift:366 | `Text("Suspended").font(.caption2).foregroundStyle(.orange)` | text-fg | warning (suspended address) | plain list row / sidebar | platform-adaptive | no |
| Cabalmail/Views/FolderListView+Helpers.swift:129 | `case .accent: AnyShapeStyle(Color("AccentColor"))` (`iconForeground`) | glyph-fg | accent (unselected folder icon) | sidebar | asset-catalog | #1318 (accent 4.68:1 on (209,209,214), 7.12:1 on white, 1.77:1 on emphasized system-blue selection) |
| Cabalmail/Views/FolderListView+Helpers.swift:144 | `case .unread: AnyShapeStyle(Color("AccentColor"))` (`folderNameForeground`) | text-fg | unread (folder has unread mail) | sidebar | asset-catalog | #1297 (rule measured; see FolderNameTint) |
| Cabalmail/Views/FolderListView+Helpers.swift:146 | `case .caughtUp: Color.primary.opacity(FolderNameTint.dimmedOpacity)` (0.7) | text-fg | other (caught-up folder, non-chromatic branch of the same rule) | sidebar | platform-adaptive | #1297 (0.7 -> 5.35:1 macOS 26.6, 8.59:1 iPadOS; 0.6 measured 4.04:1) |
| Cabalmail/Views/FolderListView+Helpers.swift:259 | `.tint(folder.isSubscribed ? .orange : .accentColor)` (subscribe swipe) | control-tint | warning (unsubscribe) / accent (subscribe) | swipe action | platform-adaptive | no |
| Cabalmail/Views/FolderListView.swift:94 | `Label(errorMessage, ...).foregroundStyle(.red)` | text-fg + glyph-fg | error-state | sidebar | platform-adaptive | no |
| Cabalmail/Views/FolderListView.swift:269 | `RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)` (drag hover) | border/stroke | selected (drop target) | sidebar row | platform-adaptive | no |
| Cabalmail/Views/FolderListView.swift:333 | `.foregroundStyle(iconForeground(isSelected:))` on folder icon | glyph-fg | accent / inherited | sidebar (unselected: material; selected: platform selection fill) | asset-catalog / inherited | #1318 |
| Cabalmail/Views/FolderListView.swift:335 | `.foregroundStyle(folderNameForeground(hasUnread:isSelected:))` on folder name | text-fg | unread / caught-up / inherited | sidebar | asset-catalog / platform-adaptive | #1297 |
| Cabalmail/Views/MessageListView+Selection.swift:46 | `Label(errorMessage, ...).foregroundStyle(.red)` | text-fg + glyph-fg | error-state | plain list | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Selection.swift:276 | `let background = selected ? Color.accentColor.opacity(0.15) : Color.clear` (row background, via :282 `.background` and :291 `rowBackground`) | wash | selected (message row) | plain list row | platform-adaptive | no |
| Cabalmail/Views/SwipeActionRow.swift:124 | `.tint(spec.tint)` on the swipe `Button` | control-tint | applies the spec tints above (red/blue) | swipe action | platform-adaptive | no |
| Cabalmail/Views/RuleEditorView.swift:123 | `Image("minus.circle.fill").foregroundStyle(.red)` (remove condition) | glyph-fg | danger/destructive | white form row | platform-adaptive | no |
| Cabalmail/Views/RuleEditorView.swift:191 | `Text("This rule would have no effect...").font(.caption).foregroundStyle(.red)` | text-fg | error-state (validation) | grouped-form grey (section) | platform-adaptive | no |
| Cabalmail/Views/RuleEditorView.swift:213 | `Image("checkmark").foregroundStyle(.tint)` (action picker) | glyph-fg | selected | white form row | platform-adaptive (env tint) | no |
| Cabalmail/Views/RuleEditorView.swift:267 | `Text("Couldn't create the folder. Try again.").foregroundStyle(.red)` | text-fg | error-state | grouped-form grey | platform-adaptive | no |
| Cabalmail/Views/RuleEditorView.swift:323 | `Image("checkmark").foregroundStyle(.tint)` (folder multi-picker) | glyph-fg | selected | white form row | platform-adaptive (env tint) | no |
| Cabalmail/Views/RuleEditorExtras.swift:54 | `Circle().fill(FlagPaletteColor.color(for: entry?.color ?? ""))` 10pt (rule flag toggles) | fill + user-data | user-flag-colour | white form row | platform-adaptive | no |
| Cabalmail/Views/RuleEditorExtras.swift:99-101 | `.foregroundStyle(count > maxReplyBodyLength ? .red : .secondary)` | text-fg | error-state (over length) | grouped-form grey | platform-adaptive | no |
| Cabalmail/Views/RuleEditorExtras.swift:106 | `Text("A reply needs some text.").foregroundStyle(.red)` | text-fg | error-state | grouped-form grey | platform-adaptive | no |
| Cabalmail/Views/RuleEditorExtras.swift:129 | `Image("minus.circle.fill").foregroundStyle(.red)` (remove forward address) | glyph-fg | danger/destructive | white form row | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:47 | `Image(systemName: icon).foregroundStyle(tint)` (`BannerView`) | glyph-fg | success / info / warning / error per caller | `.ultraThinMaterial` capsule | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:59 | `Button(...).buttonStyle(.borderless).tint(tint)` (Copy / Resume) | control-tint | same as banner kind | material capsule | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:78 | `Capsule().stroke(tint.opacity(0.3), lineWidth: 1)` | border/stroke | same as banner kind | material capsule edge | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:138 | `case .success: return .green` | user-data (kind -> colour) | success | material capsule | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:139 | `case .info: return .blue` | user-data | info | material capsule | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:140 | `case .warning: return .orange` | user-data | warning | material capsule | platform-adaptive | no |
| Cabalmail/Views/ToastBanner.swift:141 | `case .error: return .red` | user-data | error-state | material capsule | platform-adaptive | no |
| Cabalmail/Views/SignedInRootView.swift:141 | `BannerView(icon: "wifi.slash", text: "Offline ...", tint: .orange)` | glyph-fg (via BannerView) | warning (offline) | material capsule over root | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:60 | `color: FlagPalette.colors.first ?? "gray"` (new entry default = "red") | user-data | user-flag-colour (default) | n/a | n/a | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:74 | `Image(enabled ? "flag.fill" : "flag.slash").foregroundStyle(FlagPaletteColor.color(for: entry.color))` | glyph-fg + user-data | user-flag-colour | white form row (settings list) | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:86 | `case "red": .red` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:87 | `case "orange": .orange` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:88 | `case "yellow": .yellow` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:89 | `case "green": .green` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:90 | `case "teal": .teal` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:91 | `case "blue": .blue` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:92 | `case "indigo": .indigo` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:93 | `case "purple": .purple` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:94 | `case "pink": .pink` | user-data | user-flag-colour | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:95 | `default: .gray` (unknown / deleted) | user-data | user-flag-colour (fallback) | n/a | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:176 | `Circle().fill(FlagPaletteColor.color(for: name))` 32pt swatch grid | fill + user-data | user-flag-colour (picker) | white form row ("Color" section) | platform-adaptive | no |
| Cabalmail/Views/FlagPaletteSettingsView.swift:181 | `Image("checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)` | on-fill | selected (over the chosen user colour, incl. yellow) | the user colour's 32pt fill | fixed (white) | no |
| Cabalmail/Views/ComposeView+Subviews.swift:57 | `Label(warning, "exclamationmark.triangle").font(.caption).foregroundStyle(AttachmentWarningTint.tint(for: colorScheme).color)` | text-fg + glyph-fg | warning (attachment total size) | white form row (light) / (44,44,46) row (dark); macOS bottom strip | scheme-aware | #1453 (shipped `.orange` 2.31:1 light / 6.24:1 dark; darkened 5.04:1 light / 2.77:1 dark) |
| Cabalmail/Views/AttachmentWarningTint.swift:42 | `case .systemOrange: Color.orange` (dark scheme branch) | text-fg (rule value) | warning | dark form row (44,44,46) | platform-adaptive | #1453 (6.24:1) |
| Cabalmail/Views/AttachmentWarningTint.swift:51 | `systemOrangeLight = Components(red: 255, green: 141, blue: 40)` | text-fg (rule constant) | warning (recorded system value) | n/a | fixed | #1453 |
| Cabalmail/Views/AttachmentWarningTint.swift:62 | `darkeningFactor = 0.65` | text-fg (rule constant) | warning | white form row | fixed | #1453 (0.65 -> 5.04:1; 0.70 -> 4.45:1) |
| Cabalmail/Views/AttachmentWarningTint.swift:65 | `darkenedOrange = systemOrangeLight.scaled(by: 0.65)` = (166, 92, 26) | text-fg (rule value, light branch) | warning | white form row | fixed | #1453 (5.04:1 on white) |
| Cabalmail/Views/AttachmentWarningTint.swift:83 | `Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)` | text-fg (constructor) | warning | n/a | fixed | #1453 |
| Cabalmail/Views/MessageDetailView.swift:342 | `Circle().fill(FlagPaletteColor.color(for: entry?.color ?? ""))` 8pt chip dot | fill + user-data | user-flag-colour | `.quaternary` capsule (:350) over reader header | platform-adaptive | no |
| Cabalmail/Views/RulesView.swift:223 | `Image("checkmark.circle.fill").foregroundStyle(.green)` | glyph-fg | success (rules saved) | rules list status row | platform-adaptive | no |
| Cabalmail/Views/RulesView.swift:226 | `Image("exclamationmark.triangle.fill").foregroundStyle(.red)` | glyph-fg | error-state (save failed) | rules list status row | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Bulk.swift:234 | `.foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))` (bulk action bar buttons, `.plain` style) | text-fg + glyph-fg | danger/destructive / accent | bulk action bar (toolbar/bar material) | platform-adaptive | no |
| Cabalmail/Views/NewAddressSheet.swift:141 | `Label(errorMessage, ...).foregroundStyle(.red)` (macOS layout) | text-fg + glyph-fg | error-state | sheet | platform-adaptive | no |
| Cabalmail/Views/NewAddressSheet.swift:171 | `Label(errorMessage, ...).foregroundStyle(.red)` (iOS form) | text-fg + glyph-fg | error-state | white form row in sheet | platform-adaptive | no |
| Cabalmail/Views/MessageDetailView+DisposeOptions.swift:31 + :85 | `.tint(disposeTint(for:))`; `intent.isDestructive ? .red : nil` (non-macOS only) | control-tint | danger/destructive (Trash / Delete Forever menu face) | toolbar | platform-adaptive; macOS returns nil | no |
| Cabalmail/Views/DebugLogView.swift:78 | `.background(enabled ? tint(for: level).opacity(0.2) : Color.gray.opacity(0.15), in: Capsule())` | wash | level-debug/info/warn/error (filter chip on) | list section row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:80 | `.foregroundStyle(enabled ? tint(for: level) : .secondary)` | on-fill (text over its own 0.2 wash) | level-* | the same colour's 0.2 wash | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:104 | `case .debug: return .gray` | user-data (level -> colour) | level-debug | chip / list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:105 | `case .info: return .blue` | user-data | level-info | chip / list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:106 | `case .warn: return .orange` | user-data | level-warn | chip / list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:107 | `case .error: return .red` | user-data | level-error | chip / list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:150 | `Text(levelLabel).font(.caption2).fontWeight(.bold).foregroundStyle(tint)` (`LogRow`) | text-fg | level-* | plain list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:166 | `case .debug: return .gray` (`LogRow.tint`) | user-data | level-debug | plain list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:167 | `case .info: return .blue` | user-data | level-info | plain list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:168 | `case .warn: return .orange` | user-data | level-warn | plain list row | platform-adaptive | no |
| Cabalmail/Views/DebugLogView.swift:169 | `case .error: return .red` | user-data | level-error | plain list row | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Filter.swift:101-103 | `RoundedRectangle(cornerRadius: 12).fill(filter == model.filterTab ? Color.accentColor.opacity(0.18) : Color.clear)` | wash | selected (filter pill) | list header | platform-adaptive | no |
| Cabalmail/Views/MessageListView+Search.swift:79 | `Image("magnifyingglass.circle.fill").foregroundStyle(.tint)` | glyph-fg | info (search banner) | in-list banner | platform-adaptive (env tint) | no |
| Cabalmail/Views/NotificationSettingsSection.swift:269 | `Image("checkmark").foregroundStyle(.tint).opacity(selected ? 1 : 0)` | glyph-fg | selected (folder picker) | white form row | platform-adaptive (env tint) | no |
| Cabalmail/Views/AttachmentStrip.swift:75 | `Image(systemName: iconName).foregroundStyle(.tint)` (`AttachmentChip`) | glyph-fg | attachment | attachment chip | platform-adaptive (env tint) | no |
| Cabalmail/Views/MessageDrag.swift:60 | `Image(count > 1 ? "envelope.fill" : "envelope").foregroundStyle(.tint)` | glyph-fg | accent (drag preview) | drag preview capsule | platform-adaptive (env tint) | no |
| Cabalmail/Views/ContactPickerSheet.swift:90-91 | `.foregroundStyle(selected ? Color.accentColor : Color.secondary)` (checkmark.circle.fill / circle) | glyph-fg | selected | sheet list row | platform-adaptive | no |
| Cabalmail/Views/CalendarEventSheet.swift:65 | `Label("This event was cancelled", "xmark.circle").font(.caption).foregroundStyle(.red)` | text-fg + glyph-fg | danger (cancelled event) | white form row in sheet | platform-adaptive | no |
| Cabalmail/Views/AsyncContentView.swift:38 | `Label(errorMessage, ...).foregroundStyle(.red)` | text-fg + glyph-fg | error-state | plain content area | platform-adaptive | no |
| Cabalmail/Views/MessageDetailView+Scroll.swift:30 | `Label(errorMessage, ...).foregroundStyle(.red)` | text-fg + glyph-fg | error-state (body load) | reader surface | platform-adaptive | no |
| Cabalmail/Views/AvatarView.swift:100 | `Circle().fill(backgroundColor)` (initials avatar) | fill | address-swatch (per sender domain, FNV-1a keyed) | plain list row (message list) / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:104 + :147 | `Text(initials).foregroundStyle(initialsForeground)`; `Color(red: 0.20, green: 0.19, blue: 0.17)` (warm-neutral ink) | on-fill | other (initials over avatar swatch) | the avatar swatch fill | fixed | no |
| Cabalmail/Views/AvatarView.swift:123 | `Color(red: 0.86, green: 0.72, blue: 0.70) // dusty rose` | user-data (hash -> colour) | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:124 | `Color(red: 0.73, green: 0.81, blue: 0.69) // sage` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:125 | `Color(red: 0.89, green: 0.83, blue: 0.66) // sand` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:126 | `Color(red: 0.71, green: 0.80, blue: 0.85) // dusty sky` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:127 | `Color(red: 0.85, green: 0.70, blue: 0.58) // terracotta` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:128 | `Color(red: 0.79, green: 0.74, blue: 0.85) // lavender` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:129 | `Color(red: 0.67, green: 0.80, blue: 0.78) // muted teal` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:130 | `Color(red: 0.90, green: 0.78, blue: 0.66) // pale peach` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:131 | `Color(red: 0.75, green: 0.76, blue: 0.61) // moss` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/AvatarView.swift:132 | `Color(red: 0.80, green: 0.76, blue: 0.71) // taupe` | user-data | address-swatch | list row / reader header | fixed | no |
| Cabalmail/Views/HTMLRewrite.swift:52-53 | `defaultLinkStyle = "<style>a { color: #2b633a; }</style>"` (both render paths, author-overridable, light only) | text-fg (CSS) | link (brand) | white page (Original mode pins WKWebView to light: HTMLBodyView.swift:198-199, :242) | fixed (light value only) | no |
| Cabalmail/Views/HTMLRewrite.swift:85 | `brandLinkColorLight = "#2b633a"` | brand (constant) | link / accent (restates AccentColor light) | white page | fixed | no |
| Cabalmail/Views/HTMLRewrite.swift:86 | `brandLinkColorDark = "#79c289"` | brand (constant) | link / accent (restates AccentColor dark) | `#1c1c1e` page | fixed | no |
| Cabalmail/Views/HTMLRewrite.swift:120 | reader CSS `a { color: #2b633a !important; text-decoration: underline !important; }` | text-fg (CSS) | link | `#ffffff` page, text `#1c1c1e` (:102-103) | scheme-aware (`prefers-color-scheme`) | no |
| Cabalmail/Views/HTMLRewrite.swift:149 | reader CSS dark `a { color: #79c289 !important; }` | text-fg (CSS) | link | `#1c1c1e` page, text `#f2f2f7` (:141-147) | scheme-aware | no |

Non-chromatic CSS in the reader stylesheet, listed for completeness only: `#ffffff`/`#1c1c1e` page backgrounds, `#1c1c1e`/`#f2f2f7` text, `rgba(127,127,127,0.35)` blockquote rule, `rgba(127,127,127,0.12)` code background, `rgba(127,127,127,0.3)` hr (HTMLRewrite.swift:102-103, :124, :132, :138, :141-147). Non-chromatic Swift sites excluded: `MailRootView.swift:758` (`Color.black.opacity(0.15)` scrim), `:775` (`.shadow(color: .black.opacity(0.25))`), `HTMLBodyView.swift:199` (`.white` web view background), `SidebarListHeaderRow.swift:74`, `GlobalSearchField.swift:43`, `ColumnResizeHandle.swift:41`, `FolderListView.swift:343`, `MessageDetailView.swift:350`, `MessageListView+Selection.swift:332-339` (all `.secondary`/`.quaternary` fills).

## CabalmailMac (macOS app target)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| CabalmailMac/*.swift | none | - | - | - | - | - |

The Mac target's own sources (`CabalmailMacApp.swift`, `CabalmailCommands.swift`, `ComposeWindowCommand.swift`, `MainMailWindow.swift`, `MenuBarExtraMenu.swift`, `SettingsTabsView.swift`) contain no chromatic colour sites; the only colour-related code is `.preferredColorScheme(colorScheme(for: preferences.theme))` (`CabalmailMacApp.swift:39`, `:108`, `:131`), which selects the scheme, not a colour. Every table row above under Cabalmail whose file is in `Cabalmail/Views/` is compiled into this target too (per `project.yml`), and the `#if os(macOS)` branches noted there apply. Mac colour assets are in the Assets table.

## CabalmailWatch (watchOS app target)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| CabalmailWatch/ContentView.swift:62 | `Image("iphone.and.arrow.right.inward").font(.title3).foregroundStyle(.tint)` | glyph-fg | accent (waiting-for-phone state) | black (watch) | platform-adaptive (env tint = watch AccentColor 0x79C289) | no |
| CabalmailWatch/ContentView.swift:161 | `Button(... Reinstate/Suspend ...).tint(.orange)` (swipe action) | control-tint | warning (suspend / reinstate) | swipe action on black | platform-adaptive | no |
| CabalmailWatch/ContentView.swift:189 | `Image("star.fill").font(.caption2).foregroundStyle(.yellow)` | glyph-fg | flagged (favorite) | black (watch list row) | platform-adaptive | no |
| CabalmailWatch/ContentView.swift:194 | `Image("pause.circle").font(.caption2).foregroundStyle(.orange)` | glyph-fg | warning (suspended) | black (watch list row) | platform-adaptive | no |
| CabalmailWatch/NewAddressView.swift:86 | `Button { reroll }.buttonStyle(.plain).foregroundStyle(.tint)` (die.face.5) | glyph-fg (control) | accent (reroll) | black (watch) | platform-adaptive (env tint) | no |
| CabalmailWatch/NewAddressView.swift:93 | `Text(errorMessage).font(.caption2).foregroundStyle(.red)` | text-fg | error-state | black (watch) | platform-adaptive | no |
| CabalmailWatch/NewAddressView.swift:124 | `Label("Created", "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)` | text-fg + glyph-fg | success | black (watch) | platform-adaptive | no |
| CabalmailWatch/AddressDetailView.swift:25 | `Label("Favorite", "star.fill").font(.caption2).foregroundStyle(.yellow)` | text-fg + glyph-fg | flagged (favorite) | black (watch) | platform-adaptive | no |
| CabalmailWatch/AddressDetailView.swift:30 | `Label("Suspended", "pause.circle").font(.caption2).foregroundStyle(.orange)` | text-fg + glyph-fg | warning (suspended) | black (watch) | platform-adaptive | no |

## CabalmailKit (shared Swift package)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| CabalmailKit/Sources/CabalmailKit/CabalmailTokens.swift:4 | `Color.cmForest = Color(red: 0x2E/255, green: 0x52/255, blue: 0x35/255)` (#2E5235) | brand (token, no call sites in scope) | brand | unknown (unused) | fixed | no |
| CabalmailKit/Sources/CabalmailKit/CabalmailTokens.swift:5 | `Color.cmForestDeep` = #1E3A24 | brand (token, unused) | brand | unknown | fixed | no |
| CabalmailKit/Sources/CabalmailKit/CabalmailTokens.swift:6 | `Color.cmCream` = #F4EBD6 | brand (token, unused) | brand | unknown | fixed | no |
| CabalmailKit/Sources/CabalmailKit/CabalmailTokens.swift:7 | `Color.cmParchment` = #E8DFC8 | brand (token, unused) | brand | unknown | fixed | no |
| CabalmailKit/Sources/CabalmailKit/CabalmailTokens.swift:8 | `Color.cmInk` = #0F1A12 | brand (token, unused) | brand | unknown | fixed | no |
| CabalmailKit/Sources/CabalmailKit/CabalmailTokens.swift:9 | `Color.cmInkSoft` = #16241A | brand (token, unused) | brand | unknown | fixed | no |
| CabalmailKit/Sources/CabalmailKit/Settings/FlagPalette.swift:61-64 | `FlagPalette.colors = ["red","orange","yellow","green","teal","blue","indigo","purple","pink","gray"]` | user-data (wire vocabulary; mirrors `lambda/api/set_preferences`) | user-flag-colour | n/a | n/a | no |
| CabalmailKit/Sources/CabalmailKit/Settings/FlagPalette.swift:21 | `FlagPaletteEntry.color: String` | user-data (stored name) | user-flag-colour | n/a | n/a | no |

No CSS colour literals are emitted from the Kit (`ReplyBuilder`, `RichTextEditorController` checked; the editor sets `backgroundColor = .clear` only).

## Assets (asset-catalog colour sets)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| Cabalmail/Assets.xcassets/AccentColor.colorset/Contents.json | light `#2B633A` (r 0x2B, g 0x63, b 0x3A); dark `#79C289` (r 0x79, g 0xC2, b 0x89); sRGB, alpha 1 | brand | accent (unread dot, folder icon/name, address icon, link colour restated in HTMLRewrite) | sidebar / list rows / forms | asset-catalog (light + dark) | #1297, #1318 (as pinned accent) |
| Cabalmail/Assets.xcassets/LogoTint.colorset/Contents.json | light `#2E5235` (r 0x2E, g 0x52, b 0x35); dark `#8DC899` (r 0x8D, g 0xC8, b 0x99); sRGB, alpha 1 | brand | brand/logo (CabalmailMark tint) | splash / sidebar wash / mac sign-in | asset-catalog (light + dark) | no |
| CabalmailMac/Assets.xcassets/AccentColor.colorset/Contents.json | light `#2B633A`; dark `#79C289` (identical to iOS) | brand | accent | as above | asset-catalog | #1297, #1318 |
| CabalmailMac/Assets.xcassets/LogoTint.colorset/Contents.json | light `#2E5235`; dark `#8DC899` (identical to iOS) | brand | brand/logo | as above | asset-catalog | no |
| CabalmailWatch/Assets.xcassets/AccentColor.colorset/Contents.json | universal `#79C289` (r 0x79, g 0xC2, b 0x89) only, no dark variant | brand | accent (watch env tint) | black (watch) | fixed (single value; the iOS dark value) | no |

Other catalog entries (`CabalmailMark.imageset`, `MenuBarMark.imageset`, `AppIconVision.solidimagestack`, `AppIcon.appiconset`, `CabalmailMac/AppIcon.icon`) are images, not colour sets.

## Rules and mappings

**`FolderNameTint`** (`Cabalmail/Views/FolderNameTint.swift`) — decides the folder-row name colour from `(hasUnread, isSelected)`. Cases: `.inherited` (selected row, no override), `.unread` (pinned `Color("AccentColor")`), `.caughtUp` (`Color.primary.opacity(dimmedOpacity)`). Constants: `dimmedOpacity = 0.7`, `macOSVibrancyDiscount = 0.85`. Ratios in comments (#1294 caused, #1297 measured): pinned white on iPadOS unemphasized selection (209,209,214) 1.52:1 and on the un-filled duplicate "All folders" row 1.00:1; `.secondary` resolves to 50% black on iPadOS = 4.00:1 over white (under 4.5:1 AA), ~46% on macOS 27 = 2.90-3.31:1 over sidebar material, ~59% on macOS 26 = 5.29:1; opacity 0.6 measured 4.04:1 on macOS 26.6 (regression), 0.7 measures 5.35:1 on macOS 26.6 and 8.59:1 on iPadOS; nominal 0.6/0.7 composite as 0.51/0.59 over macOS background (236,240,243). Selection wins over unread. Applied at `FolderListView+Helpers.swift:139-148` and `FolderListView.swift:335`.

**`FolderIconTint`** (`Cabalmail/Views/FolderIconTint.swift`) — decides the folder-row icon colour from `isSelected`. Cases: `.inherited` (selected: `.primary`), `.accent` (unselected: `Color("AccentColor")`). Ratios in comments (#1318): former pinned white measured 1.52:1 on (209,209,214) and 1.00:1 on no fill; brand accent measures 4.68:1 and 7.12:1 on those two, but 1.77:1 against an emphasized system-blue selection. Applied at `FolderListView+Helpers.swift:124-131` and `FolderListView.swift:333`.

**`AttachmentWarningTint`** (`Cabalmail/Views/AttachmentWarningTint.swift`) — decides the compose attachment-size warning colour from `ColorScheme`. Cases: `.systemOrange` (dark: `Color.orange`), `.darkened` (light: `Color(.sRGB, 166/255, 92/255, 26/255)`). Constants: `systemOrangeLight = (255,141,40)` (dark resolves (255,146,48)), `darkeningFactor = 0.65`, `darkenedOrange = (166,92,26)`. Ratios (#1453): shipped orange 2.31:1 on white / 6.24:1 on (44,44,46); darkened 5.04:1 / 2.77:1; factor 0.70 would be 4.45:1. Applied at `ComposeView+Subviews.swift:57`. Changelog fragment: `changelog.d/attachment-warning-contrast.fixed.md`.

**`FlagPaletteColor`** (`Cabalmail/Views/FlagPaletteSettingsView.swift:83-97`) — maps the stored wire name to a SwiftUI colour: red -> `.red`, orange -> `.orange`, yellow -> `.yellow`, green -> `.green`, teal -> `.teal`, blue -> `.blue`, indigo -> `.indigo`, purple -> `.purple`, pink -> `.pink`, anything else (incl. "gray" and deleted/unknown) -> `.gray`. Vocabulary source: `FlagPalette.colors` (Kit). New entries default to `colors.first` = "red". Consumed at `MessageListView+Rows.swift:475`, `MessageDetailView.swift:342`, `RuleEditorExtras.swift:54`, `FlagPaletteSettingsView.swift:74` and `:176`.

**`ToastBanner.tint`** (`ToastBanner.swift:136-143`) — `Toast.Kind` -> colour: success `.green`, info `.blue`, warning `.orange`, error `.red`; used as glyph, button tint, and 0.3 capsule stroke. `SignedInRootView.swift:141` adds an offline banner at `.orange`.

**`AuthResultsLine.color(for:)`** (`AuthResultsLine.swift:63-69`) — `AuthMethodSeverity` -> colour: ok `.green`, bad `.orange`, neutral `.secondary`; drawn as chip text over the same colour at 0.12.

**`DebugLogView.tint(for:)` / `LogRow.tint`** (`DebugLogView.swift:102-108`, `:164-170`) — log level -> colour: debug `.gray`, info `.blue`, warn `.orange`, error `.red`.

**`SwipeActionSpec` tints** (`MessageListView+Rows.swift:301-350`, applied by `SwipeActionRow.swift:124`) — purge `.red` (destructive), archive/trash `.red` (destructive), restore `.blue`, read/unread toggle `.blue`. Address swipes: suspend/reinstate `.orange`, favorite `.yellow` / unfavorite `.gray` (`AddressListView.swift:293`, `:310`); folder subscribe swipe `.orange` when subscribed else `.accentColor` (`FolderListView+Helpers.swift:259`); watch suspend `.orange` (`CabalmailWatch/ContentView.swift:161`).

**`SidebarWash` swatches** (`SidebarBranding.swift:44-65`) — the four admin-app address swatches from `react/admin/src/utils/addressSwatch.js`, light/dark: azure `#286CAB`/`#79BDFF`, amber `#A16100`/`#FAB45F`, forest `#2B633A`/`#79C289`, plum `#793974`/`#E39BDC`. Each is an elliptical gradient fading to alpha 0 at 70% radius, whole layer at 0.20 opacity, scheme selected by `colorScheme`. No "oxblood" or "ink" swatch exists in the Apple sources.

**`AvatarView` palette** (`AvatarView.swift:122-133`) — 10 fixed pastels keyed by FNV-1a hash of the lowercased sender host: dusty rose (0.86,0.72,0.70), sage (0.73,0.81,0.69), sand (0.89,0.83,0.66), dusty sky (0.71,0.80,0.85), terracotta (0.85,0.70,0.58), lavender (0.79,0.74,0.85), muted teal (0.67,0.80,0.78), pale peach (0.90,0.78,0.66), moss (0.75,0.76,0.61), taupe (0.80,0.76,0.71); initials ink (0.20,0.19,0.17). Same values in both schemes.

**Brand hex restatements** — `HTMLRewrite.swift:85-86` restates AccentColor as `#2b633a` / `#79c289` for CSS (comment asks to keep them in step with both app targets' `AccentColor.colorset`). `CabalmailTokens.swift` defines `cmForest #2E5235` (equals LogoTint light), `cmForestDeep #1E3A24`, `cmCream #F4EBD6`, `cmParchment #E8DFC8`, `cmInk #0F1A12`, `cmInkSoft #16241A`; none is referenced anywhere in scope.

**`ContactsPickerAffordance.tintOpacity`** (`ContactsPickerAffordance.swift:52`) — 1.0 when enabled, 0.35 when inert; multiplies `Color.accentColor` at `RecipientFieldWithSuggestions.swift:68`.

## Counts

Rows: Cabalmail 128, CabalmailMac 1 (placeholder "none"), CabalmailWatch 9, CabalmailKit 8, Assets 5. Total 151 rows (150 sites + 1 placeholder).

Sites per colour, counted over the table rows (a row naming two colours is counted under each; mapping rows are counted by the colour they name):

| colour | rows |
|---|---|
| red (`.red` / `"red"`) | 31 |
| orange (`.orange` / `"orange"` / systemOrange and the derived (166,92,26)) | 21 |
| environment accent (`Color.accentColor`, `.accentColor`, `.foregroundStyle(.tint)`) | 19 |
| AccentColor asset (`Color("AccentColor")`, `#2b633a` / `#79c289`, colorset entries) | 14 |
| avatar pastels (`Color(red:green:blue:)` in AvatarView incl. ink) | 11 |
| blue | 7 |
| gray (as a chosen palette / level value) | 7 |
| sidebar swatch hex (azure / amber / forest / plum, gradient, 0.20 opacity, `init(rgb:)`) | 7 |
| dynamic `tint` parameter (BannerView glyph / button / stroke, SwipeActionRow, DebugLog chip and row) | 7 |
| green | 6 |
| yellow | 6 |
| Kit brand tokens (`cmForest`, `cmForestDeep`, `cmCream`, `cmParchment`, `cmInk`, `cmInkSoft`) | 6 |
| LogoTint asset (`Color("LogoTint")`, colorset entries) | 5 |
| user-flag palette, dynamic (`FlagPaletteColor.color(for:)` call sites) | 5 |
| teal / indigo / purple / pink (one mapping row each) | 4 |

Rows per primary role (first role named in the row):

| role | rows |
|---|---|
| user-data (name / level / kind / hash -> colour mappings and stored vocabularies) | 37 |
| text-fg (incl. `Label` rows that are text + glyph, CSS link rules, rule constants) | 36 |
| glyph-fg | 29 |
| brand (tokens, hex constants, asset colour sets) | 13 |
| wash | 12 |
| control-tint | 11 |
| fill | 6 |
| on-fill | 4 |
| border/stroke | 2 |
| shadow (chromatic) | 0 |
| none (CabalmailMac placeholder) | 1 |
