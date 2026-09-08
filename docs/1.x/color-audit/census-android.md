# Android client colour census

Scope: `android/app/src/main` and `android/kit/src/main` (Kotlin, resources, assets). Excludes tests and `app/src/main/play/`. Paths below are relative to `android/`. Neutral scheme roles (surface, surfaceVariant, outline, onSurface, onSurfaceVariant, inverseSurface) and `Color.Transparent` / `android.graphics.Color.TRANSPARENT` are not listed; the sixteen toolbar/notification vector drawables that fill with `@android:color/white` are monochrome templates tinted at the `Icon()` call site and are likewise omitted.

Abbreviations: `cs.` = `MaterialTheme.colorScheme.`; "dialog" = AlertDialog container (`surfaceContainerHigh`); "menu" = DropdownMenu container (`surfaceContainer`).

## app module (`app/src/main/kotlin/com/cabalmail/android/`)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| ui/theme/Theme.kt:45 | `LocalLogoTint = staticCompositionLocalOf { Color(0xFF2E5235) }` | brand | brand/logo (fallback default when no provider) | surface | fixed (overridden at :160) | no |
| ui/theme/Theme.kt:79 | `Accent.INK -> Color(0xFF1F2A44)` | scheme-seed | accent | n/a | fixed | no |
| ui/theme/Theme.kt:80 | `Accent.OXBLOOD -> Color(0xFF6B1F2A)` | scheme-seed | accent | n/a | fixed | no |
| ui/theme/Theme.kt:81 | `Accent.FOREST -> Color(0xFF1F5B3A)` | scheme-seed | accent (default) | n/a | fixed | no |
| ui/theme/Theme.kt:82 | `Accent.AZURE -> Color(0xFF1B5E9E)` | scheme-seed | accent | n/a | fixed | no |
| ui/theme/Theme.kt:83 | `Accent.AMBER -> Color(0xFFB0651B)` | scheme-seed | accent | n/a | fixed | no |
| ui/theme/Theme.kt:84 | `Accent.PLUM -> Color(0xFF5B2A6B)` | scheme-seed | accent | n/a | fixed | no |
| ui/theme/Theme.kt:96 | `primary = seed.lighten(0.45f)` (dark) | scheme-seed | accent | n/a | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:97 | `onPrimary = Color(0xFF10141A)` (dark) | on-fill | accent (content over primary) | primary fill | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:98 | `primaryContainer = seed.darken(0.25f)` (dark) | scheme-seed | accent | n/a | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:99 | `onPrimaryContainer = seed.lighten(0.75f)` (dark) | scheme-seed | accent | primaryContainer fill | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:100 | `secondary = seed.lighten(0.3f)` (dark) | scheme-seed | accent | n/a | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:101 | `secondaryContainer = seed.darken(0.4f)` (dark) | scheme-seed | selected / success (see uses) | n/a | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:102 | `onSecondaryContainer = seed.lighten(0.7f)` (dark) | scheme-seed | accent | secondaryContainer fill | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:103 | `tertiary = seed.lighten(0.55f)` (dark) | scheme-seed | flagged (see uses) | n/a | theme-aware (dark branch) | no |
| ui/theme/Theme.kt:107 | `primary = seed` (light) | scheme-seed | accent | n/a | theme-aware (light branch) | no |
| ui/theme/Theme.kt:108 | `onPrimary = Color.White` (light) | on-fill | accent (content over primary) | primary fill | theme-aware (light branch) | no |
| ui/theme/Theme.kt:109 | `primaryContainer = seed.lighten(0.8f)` (light) | scheme-seed | accent | n/a | theme-aware (light branch) | no |
| ui/theme/Theme.kt:110 | `onPrimaryContainer = seed.darken(0.5f)` (light) | scheme-seed | accent | primaryContainer fill | theme-aware (light branch) | no |
| ui/theme/Theme.kt:111 | `secondary = seed.darken(0.15f)` (light) | scheme-seed | accent | n/a | theme-aware (light branch) | no |
| ui/theme/Theme.kt:112 | `secondaryContainer = seed.lighten(0.85f)` (light) | scheme-seed | selected / success (see uses) | n/a | theme-aware (light branch) | no |
| ui/theme/Theme.kt:113 | `onSecondaryContainer = seed.darken(0.5f)` (light) | scheme-seed | accent | secondaryContainer fill | theme-aware (light branch) | no |
| ui/theme/Theme.kt:114 | `tertiary = seed.darken(0.3f)` (light) | scheme-seed | flagged (see uses) | n/a | theme-aware (light branch) | no |
| ui/theme/Theme.kt:153 | `dynamicDarkColorScheme(context)` | scheme-seed | accent (Material You, wallpaper-derived) | n/a | theme-aware (dark) | no |
| ui/theme/Theme.kt:154 | `dynamicLightColorScheme(context)` | scheme-seed | accent (Material You, wallpaper-derived) | n/a | theme-aware (light) | no |
| ui/theme/Theme.kt:160 | `LocalLogoTint provides colorResource(if (darkTheme) R.color.logo_mint else R.color.logo_forest)` | brand | brand/logo | surface (top bar) | theme-aware (branches on darkTheme; values from `values/logo.xml`, no `values-night/`) | no |
| ui/settings/FlagPaletteSettings.kt:114 | `FlagPaletteEntry(..., color = FlagPalette.COLORS.first())` | user-data | user-flag-colour (new entry defaults to `"red"`) | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:193 | `Text(flags_delete, color = cs.error)` | text-fg | danger/destructive | dialog | material-role | no |
| ui/settings/FlagPaletteSettings.kt:210 | `Text(flags_delete, color = cs.error)` (confirm dialog) | text-fg | danger/destructive | dialog | material-role | no |
| ui/settings/FlagPaletteSettings.kt:235 | `.background(flagColor(name))` (36dp swatch) | fill | user-flag-colour | dialog | fixed | no |
| ui/settings/FlagPaletteSettings.kt:245 | `Icon(Check, tint = Color.White)` | on-fill | selected | the swatch's flag-colour fill | fixed | no |
| ui/settings/FlagPaletteSettings.kt:271 | `"red" -> Color(0xFFD32F2F)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:272 | `"orange" -> Color(0xFFF57C00)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:273 | `"yellow" -> Color(0xFFF9A825)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:274 | `"green" -> Color(0xFF388E3C)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:275 | `"teal" -> Color(0xFF00897B)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:276 | `"blue" -> Color(0xFF1976D2)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:277 | `"indigo" -> Color(0xFF3949AB)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:278 | `"purple" -> Color(0xFF8E24AA)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:279 | `"pink" -> Color(0xFFD81B60)` | user-data | user-flag-colour | n/a | fixed | no |
| ui/settings/FlagPaletteSettings.kt:280 | `else -> Color(0xFF757575)` (covers `"gray"` and unknown names) | user-data | user-flag-colour (gray / unknown) | n/a | fixed | no |
| ui/settings/SettingsScreen.kt:179 | `containerColor = cs.secondaryContainer` (selected category, wide layout) | fill | selected | list row | material-role | no |
| ui/settings/SettingsScreen.kt:281 | `Text(sign_out, color = cs.error)` | text-fg | danger/destructive | list row | material-role | no |
| ui/auth/SignInScreen.kt:76 | `Text(app_name, color = cs.primary)` | text-fg | brand (app title in accent) | surface | material-role | no |
| ui/auth/SignInScreen.kt:183 | `Text(message, color = cs.error)` | text-fg | error-state | surface | material-role | no |
| ui/mail/DisposeSplitButton.kt:81 | `intent.isDestructive -> cs.error` (icon tint) | glyph-fg | danger/destructive | top bar | material-role | no |
| ui/mail/MessageDetailScreen.kt:229 | `tint = if (isFlagged) cs.tertiary else cs.onSurfaceVariant` | glyph-fg | flagged | top bar | material-role | no |
| ui/mail/MessageDetailScreen.kt:266 | `.background(flagColor(palette.firstOrNull{...}?.color ?: ""))` (10dp dot, flag menu) | fill | user-flag-colour | menu | fixed | no |
| ui/mail/MessageDetailScreen.kt:335 | `Text(message, color = cs.error)` | text-fg | error-state | surface | material-role | no |
| ui/mail/MessageDetailScreen.kt:552 | `.background(flagColor(entry?.color ?: ""))` (8dp dot, keyword chip) | fill | user-flag-colour | surfaceVariant chip | fixed | no |
| ui/mail/MessageDetailScreen.kt:609 | `Surface(color = cs.secondaryContainer)` (SPF/DKIM/DMARC pass chip) | fill | success | surface (header) | material-role | no |
| ui/mail/MessageDetailScreen.kt:611 | `Surface(color = cs.errorContainer)` (SPF/DKIM/DMARC fail chip) | fill | auth-bad | surface (header) | material-role | no |
| ui/mail/MessageDetailScreen.kt:614 | `Text(label)` inside the chip Surface (implicit `contentColorFor` → onSecondaryContainer / onErrorContainer) | on-fill | success / auth-bad | the chip's container fill | material-role | no |
| ui/mail/MessageListScreen.kt:254 | `Text(message, color = cs.error)` | text-fg | error-state | surface | material-role | no |
| ui/mail/MessageListScreen.kt:596 | `cs.primary.copy(alpha = 0.12f).compositeOver(cs.surface)` (highlighted row) | wash | selected (keyboard cursor / open-in-pane) | surface | material-role | no |
| ui/mail/MessageListScreen.kt:618 | `SwipeRow(containerColor = rowColor)` (the wash passed as the opaque swipe backing) | fill | selected | list row | material-role | no |
| ui/mail/MessageListScreen.kt:673 | `.background(flagColor(entry.color))` (10dp dot, row context menu) | fill | user-flag-colour | menu | fixed | no |
| ui/mail/MessageListScreen.kt:730 | `Text(purge, color = cs.error)` | text-fg | danger/destructive | dialog | material-role | no |
| ui/mail/FolderListScreen.kt:153 | `Icon(cabalmail_mark, tint = LocalLogoTint.current)` | glyph-fg | brand/logo | top bar | theme-aware (via LocalLogoTint) | no |
| ui/mail/FolderListScreen.kt:188 | `Text(message, color = cs.error)` | text-fg | error-state | surface | material-role | no |
| ui/mail/FolderListScreen.kt:235 | `Text(empty_trash, color = cs.error)` | text-fg | danger/destructive | dialog | material-role | no |
| ui/mail/FolderListScreen.kt:295 | `Icon(KeyboardArrowRight, tint = cs.primary)` (section chevron) | glyph-fg | accent | surface | material-role | no |
| ui/mail/FolderListScreen.kt:301 | `Text(title, color = cs.primary)` (section header) | text-fg | accent | surface | material-role | no |
| ui/mail/FolderListScreen.kt:322 | `color = if (hasUnread) cs.primary else cs.onSurfaceVariant` (folder name) | text-fg | unread | list row, or secondaryContainer when the row is selected (:330) | material-role | no |
| ui/mail/FolderListScreen.kt:330 | `ListItemDefaults.colors(containerColor = cs.secondaryContainer)` (selected folder) | fill | selected | list row | material-role | no |
| ui/mail/FolderListScreen.kt:346 | `Badge { Text(badge) }` (M3 default: container `cs.error`, content `cs.onError`) | fill + on-fill | other (folder count badge) | list row / secondaryContainer when selected | material-role | no |
| ui/mail/FolderListScreen.kt:353 | `Icon(Delete, tint = cs.error)` (Trash row) | glyph-fg | danger/destructive | list row | material-role | no |
| ui/mail/PlainTextLinks.kt:104 | `val linkColor = cs.primary` → `SpanStyle(color = linkColor, Underline)` at :109 | text-fg | link | surface | material-role | no |
| ui/mail/EnvelopeRow.kt:114 | `.background(if (isSeen) Color.Transparent else cs.primary)` (8dp dot) | fill | unread | list row (surface or the :596 wash) | material-role | no |
| ui/mail/EnvelopeRow.kt:159 | `Text("!", color = cs.error)` | text-fg | other (high priority) | list row | material-role | no |
| ui/mail/EnvelopeRow.kt:167 | `Icon(Warning, tint = cs.error)` | glyph-fg | auth-bad | list row | material-role | no |
| ui/mail/EnvelopeRow.kt:176 | `Icon(Star, tint = cs.tertiary)` | glyph-fg | flagged | list row | material-role | no |
| ui/mail/EnvelopeRow.kt:192 | `.background(flagColor(entry?.color ?: ""))` (8dp dots, up to 4) | fill | user-flag-colour | list row | fixed | no |
| ui/mail/EnvelopeRow.kt:265 | `.background(Color.hsv(hue, 0.35f, 0.55f))`, `hue = address.hashCode().mod(360)` (40dp avatar) | fill | address-swatch (sender avatar) | list row | fixed | no |
| ui/mail/EnvelopeRow.kt:270 | `Text(initial, color = Color.White)` | on-fill | address-swatch | the avatar's hsv fill | fixed | no |
| ui/mail/EnvelopeRow.kt:366 | `cs.secondaryContainer` (swipe start-to-end backing) | fill | other (toggle read swipe) | list row | material-role | no |
| ui/mail/EnvelopeRow.kt:372 | `cs.errorContainer` (swipe end-to-start backing) | fill | danger/destructive (dispose / purge) | list row | material-role | no |
| ui/mail/EnvelopeRow.kt:381 | `Icon(icon, ...)` with no tint (inherits `LocalContentColor` = onSurface, since `Modifier.background` does not set content colour) | on-fill | other / danger (swipe glyph) | secondaryContainer or errorContainer fill | material-role | no |
| ui/mail/SearchScreen.kt:102 | `Text(message, color = cs.error)` | text-fg | error-state | surface | material-role | no |
| ui/compose/NewAddressSheet.kt:151 | `Text(it, color = cs.error)` | text-fg | error-state | sheet | material-role | no |
| ui/compose/RecipientField.kt:136 | `cursorBrush = SolidColor(cs.primary)` | control-tint | accent | surface (compose field) | material-role | no |
| ui/rules/RulesScreen.kt:144 | `Text(message, color = cs.error)` | text-fg | error-state | surface | material-role | no |
| ui/rules/RulesScreen.kt:279 | `Text(saveState.message, color = cs.error)` | text-fg | error-state | surface (save bar) | material-role | no |
| ui/rules/RuleEditorScreen.kt:170 | `Text(text, color = cs.primary)` (SectionLabel) | text-fg | accent | surface | material-role | no |
| ui/rules/RuleEditorScreen.kt:183 | `color = if (error) cs.error else cs.onSurfaceVariant` (Hint) | text-fg | error-state | surface | material-role | no |
| ui/rules/RuleEditorScreen.kt:465 | `color = flagColor(entry?.color ?: "")` → `.background(color)` at :637 (10dp dot) | fill | user-flag-colour | surface | fixed | no |
| ui/compose/ComposeScreen.kt:187 | `tint = if (canSend) cs.primary else cs.onSurfaceVariant.copy(alpha = 0.5f)` (Send) | glyph-fg | accent (enabled send) | top bar | material-role | no |
| ui/compose/ComposeScreen.kt:316 | `Text(compose_discard, color = cs.error)` | text-fg | danger/destructive | dialog | material-role | no |
| ui/compose/ComposeScreen.kt:402 | `Text("★ ", color = cs.tertiary)` (favourite From address) | text-fg | flagged (favourite) | menu | material-role | no |
| ui/compose/ComposeScreen.kt:428 | `Text(compose_create_address, color = cs.primary)` | text-fg | accent (action item) | menu | material-role | no |
| ui/compose/ComposeScreen.kt:516 | `Icon(Warning, tint = cs.error)` (attachment size) | glyph-fg | warning | surface | material-role | no |
| ui/compose/ComposeScreen.kt:522 | `Text(..., color = cs.error)` (attachment size) | text-fg | warning | surface | material-role | no |
| ui/compose/ComposeScreen.kt:133 | `SnackbarHost(snackbarHostState)` (M3 default inverseSurface / inverseOnSurface; no `actionLabel` ever passed, so no `inversePrimary`) | control-tint | info | surface | material-role | no |
| navigation/CabalmailNavHost.kt:324 | `SnackbarHost(hostState = snackbarHostState, ...)`; :190 and :304 pass `actionLabel` → action text is `cs.inversePrimary` | control-tint | info (action label is chromatic) | inverseSurface | material-role | no |
| navigation/CabalmailNavHost.kt:340 | `Surface(color = cs.errorContainer)` (OfflineBanner) | fill | warning (offline) | top of window, above status bar inset | material-role | no |
| navigation/CabalmailNavHost.kt:341 | `contentColor = cs.onErrorContainer` (OfflineBanner text) | on-fill | warning (offline) | errorContainer fill | material-role | no |
| ui/addresses/AddressesScreen.kt:78 | `SnackbarHost(snackbarHostState)` (no `actionLabel`) | control-tint | info | surface | material-role | no |
| ui/addresses/AddressesScreen.kt:162 | `Text(addresses_revoke, color = cs.error)` | text-fg | danger/destructive | dialog | material-role | no |
| ui/addresses/AddressesScreen.kt:202 | `.background(cs.errorContainer)` (swipe-to-revoke backing) | fill | danger/destructive | list row | material-role | no |
| ui/addresses/AddressesScreen.kt:208 | `Icon(Delete, tint = cs.onErrorContainer)` | on-fill | danger/destructive | errorContainer fill | material-role | no |
| ui/addresses/AddressesScreen.kt:237 | `tint = if (favorite) cs.tertiary else cs.onSurfaceVariant` (Star) | glyph-fg | flagged (favourite) | list row | material-role | no |
| ui/addresses/AddressesScreen.kt:259 | `Text(addresses_revoke, color = cs.error)` (long-press menu) | text-fg | danger/destructive | menu | material-role | no |
| ui/folders/FoldersAdminScreen.kt:74 | `SnackbarHost(snackbarHostState)` (no `actionLabel`) | control-tint | info | surface | material-role | no |
| ui/folders/FoldersAdminScreen.kt:138 | `Text(folders_delete, color = cs.error)` (menu) | text-fg | danger/destructive | menu | material-role | no |
| ui/folders/FoldersAdminScreen.kt:178 | `Text(folders_delete, color = cs.error)` (confirm dialog) | text-fg | danger/destructive | dialog | material-role | no |

## kit module (`kit/src/main/kotlin/com/cabalmail/kit/`)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| settings/FlagPalette.kt:44 | `COLORS = listOf("red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray")` | user-data | user-flag-colour (wire vocabulary, picker order) | n/a | fixed | no |
| settings/AppPreferences.kt:73 | `INK("ink")` | user-data | accent (wire name) | n/a | fixed | no |
| settings/AppPreferences.kt:74 | `OXBLOOD("oxblood")` | user-data | accent (wire name) | n/a | fixed | no |
| settings/AppPreferences.kt:75 | `FOREST("forest")` | user-data | accent (wire name) | n/a | fixed | no |
| settings/AppPreferences.kt:76 | `AZURE("azure")` | user-data | accent (wire name) | n/a | fixed | no |
| settings/AppPreferences.kt:77 | `AMBER("amber")` | user-data | accent (wire name) | n/a | fixed | no |
| settings/AppPreferences.kt:78 | `PLUM("plum")` | user-data | accent (wire name) | n/a | fixed | no |
| settings/AppPreferences.kt:116 | `val accent: Accent = Accent.FOREST` | user-data | accent (default) | n/a | fixed | no |
| settings/AppPreferences.kt:144 | `val dynamicColor: Boolean = true` | scheme-seed | accent (Material You default ON) | n/a | fixed | no |
| settings/PreferencesRepository.kt:40 | `ACCENT = stringPreferencesKey("accent")` (read :111, written :143) | user-data | accent (local persistence) | n/a | fixed | no |
| settings/PreferencesRepository.kt:126 | `dynamicColor = store[Keys.DYNAMIC_COLOR] ?: defaults.dynamicColor` (written :156) | scheme-seed | accent (Material You toggle persistence) | n/a | fixed | no |
| settings/PreferencesWire.kt:36 | `accent = preferences.accent.wire` (push) / :75 `wireEnum<Accent>(remote.accent)` (pull) | user-data | accent (server sync) | n/a | fixed | no |
| models/Models.kt:265 | `val accent: String = "forest"` (server preferences model) / :278 `val accent: String? = null` (patch) | user-data | accent (wire) | n/a | fixed | no |
| models/BodyFormatting.kt:54 | `foreground = if (darkMode) "#e4e2dd" else "#1a1c1a"` | text-fg | other (reader body text) | reader background (:55) | theme-aware (`darkMode` = `isSystemInDarkTheme()` at MessageDetailScreen.kt:376, not the app theme preference) | no |
| models/BodyFormatting.kt:55 | `background = if (darkMode) "#121412" else "#fdfcf8"` | fill | other (reader page background) | WebView | theme-aware (same caveat) | no |
| models/BodyFormatting.kt:56 | `link = if (darkMode) "#9ccc9c" else "#2e6b30"` | text-fg | link | reader background | theme-aware (same caveat; fixed greens, not the accent) | no |
| models/BodyFormatting.kt:61 | `html { background: $background !important; }` | fill | other (reader page background) | WebView | theme-aware | no |
| models/BodyFormatting.kt:66 | `color: $foreground !important; background: $background !important;` (body) | text-fg + fill | other (reader body) | WebView | theme-aware | no |
| models/BodyFormatting.kt:74 | `a { color: $link !important; }` | text-fg | link | reader background | theme-aware | no |

## resources (`app/src/main/res/`)

| file:line | expression | role | meaning | drawn on | appearance handling | measured? |
|---|---|---|---|---|---|---|
| values/logo.xml:4 | `<color name="logo_forest">#2E5235</color>` | brand | brand/logo | n/a | fixed (no `values-night/` exists; selection is done in Kotlin at Theme.kt:160) | no |
| values/logo.xml:5 | `<color name="logo_mint">#8DC899</color>` | brand | brand/logo (dark-mode ink) | n/a | fixed (same) | no |
| values/themes.xml:9 | `<item name="android:windowSplashScreenBackground">@color/logo_forest</item>` | fill | brand/logo (splash) | splash window | fixed (forest in both light and dark) | no |
| drawable/ic_launcher_background.xml:17 | `<item android:offset="0" android:color="#FAF4E4" />` (gradient start) | fill | brand/logo (launcher background) | launcher | fixed | no |
| drawable/ic_launcher_background.xml:18 | `<item android:offset="1" android:color="#EFE2C0" />` (gradient end) | fill | brand/logo (launcher background) | launcher | fixed | no |
| drawable/ic_launcher_foreground.xml:14 | `android:fillColor="#2E5235"` (C glyph) | glyph-fg | brand/logo | launcher gradient (#FAF4E4→#EFE2C0); alpha reused as the monochrome themed-icon layer | fixed | no |
| drawable/ic_launcher_foreground.xml:18 | `android:fillColor="#2E5235"` (envelope glyph) | glyph-fg | brand/logo | launcher gradient | fixed | no |
| drawable/cabalmail_mark.xml:10 | `android:fillColor="#2E5235"` (C glyph) | glyph-fg | brand/logo | top bar (overridden at runtime by `Icon(tint = LocalLogoTint.current)`, FolderListScreen.kt:153) | fixed in the asset; theme-aware at the call site | no |
| drawable/cabalmail_mark.xml:14 | `android:fillColor="#2E5235"` (envelope glyph) | glyph-fg | brand/logo | top bar (same override) | fixed in the asset; theme-aware at the call site | no |

## Rules and mappings

### Accent seed table (`ui/theme/Theme.kt:77-85`)

| Accent (wire name) | seed |
|---|---|
| INK (`ink`) | `#1F2A44` |
| OXBLOOD (`oxblood`) | `#6B1F2A` |
| FOREST (`forest`, default) | `#1F5B3A` |
| AZURE (`azure`) | `#1B5E9E` |
| AMBER (`amber`) | `#B0651B` |
| PLUM (`plum`) | `#5B2A6B` |

Display labels come from `SettingsRows.kt:254-262` → `strings.xml:267-272` (Ink, Oxblood, Forest, Azure, Amber, Plum).

### Scheme derivation (`accentScheme`, `Theme.kt:87-128`)

`lighten(a)`: each RGB channel `c + (1 - c) * a` (linear blend toward white). `darken(a)`: each channel `c * (1 - a)` (linear blend toward black). Both operate in sRGB, not HCT/tonal palettes, so hue drifts toward grey at high `a`. Only these roles are set; every other role (error, errorContainer, onError, onErrorContainer, surfaces, outline, inversePrimary, ...) is the M3 `lightColorScheme()`/`darkColorScheme()` default (light: error `#B3261E`, errorContainer `#F9DEDC`, onErrorContainer `#410E0B`; dark: error `#FFB4AB`, errorContainer `#93000A`, onErrorContainer `#FFDAD6`). `onSecondary`, `onTertiary`, `tertiaryContainer`, `onTertiaryContainer` are M3 defaults too, so `tertiary` is seed-derived but its container roles are the M3 purple-ish defaults (unused in the app).

| role | light | dark |
|---|---|---|
| primary | seed | seed.lighten(0.45) |
| onPrimary | `Color.White` | `#10141A` |
| primaryContainer | seed.lighten(0.80) | seed.darken(0.25) |
| onPrimaryContainer | seed.darken(0.50) | seed.lighten(0.75) |
| secondary | seed.darken(0.15) | seed.lighten(0.30) |
| secondaryContainer | seed.lighten(0.85) | seed.darken(0.40) |
| onSecondaryContainer | seed.darken(0.50) | seed.lighten(0.70) |
| tertiary | seed.darken(0.30) | seed.lighten(0.55) |

Resolved values (computed from the formulas above, rounded):

| LIGHT | primary | primaryContainer | onPrimaryContainer | secondary | secondaryContainer | onSecondaryContainer | tertiary |
|---|---|---|---|---|---|---|---|
| INK | #1F2A44 | #D2D4DA | #101522 | #1A243A | #DDDFE3 | #101522 | #161D30 |
| OXBLOOD | #6B1F2A | #E1D2D4 | #361015 | #5B1A24 | #E9DDDF | #361015 | #4B161D |
| FOREST | #1F5B3A | #D2DED8 | #102E1D | #1A4D31 | #DDE6E1 | #102E1D | #164029 |
| AZURE | #1B5E9E | #D1DFEC | #0E2F4F | #175086 | #DDE7F0 | #0E2F4F | #13426F |
| AMBER | #B0651B | #EFE0D1 | #58320E | #965617 | #F3E8DD | #58320E | #7B4713 |
| PLUM | #5B2A6B | #DED4E1 | #2E1536 | #4D245B | #E6DFE9 | #2E1536 | #401D4B |

| DARK | primary | primaryContainer | onPrimaryContainer | secondary | secondaryContainer | onSecondaryContainer | tertiary |
|---|---|---|---|---|---|---|---|
| INK | #848A98 | #172033 | #C7CAD0 | #626A7C | #131929 | #BCBFC7 | #9A9FAB |
| OXBLOOD | #AE848A | #501720 | #DAC7CA | #97626A | #401319 | #D3BCBF | #BC9A9F |
| FOREST | #84A593 | #17442C | #C7D6CE | #628C75 | #133723 | #BCCEC4 | #9AB5A6 |
| AZURE | #82A6CA | #144676 | #C6D7E7 | #5F8EBB | #10385F | #BBCFE2 | #98B7D3 |
| AMBER | #D4AA82 | #844C14 | #EBD8C6 | #C8935F | #6A3D10 | #E7D1BB | #DBBA98 |
| PLUM | #A58AAE | #442050 | #D6CADA | #8C6A97 | #371940 | #CEBFD3 | #B59FBC |

### Dynamic colour (Material You)

Yes. `AppPreferences.dynamicColor` defaults to `true` (`AppPreferences.kt:144`); `CabalmailTheme` (`Theme.kt:151-156`) uses `dynamicDarkColorScheme` / `dynamicLightColorScheme` whenever it is on (API 31 floor, no version check) and only falls back to `accentScheme(preferences.accent, darkTheme)` when it is off. The Settings "Accent" picker is disabled while dynamic colour is on (`SettingsScreen.kt:411-421`; hint text `strings.xml:237`). Under Material You every `cs.*` site in the app tables is wallpaper-derived, including `error*` (M3 dynamic schemes keep the standard error tones). Not replaced by dynamic colour: `LocalLogoTint` (deliberately fixed brand ink, `Theme.kt:39-45`), `flagColor(...)` (cross-client fixed palette, `FlagPaletteSettings.kt:264-268`), the sender avatar `Color.hsv` (`EnvelopeRow.kt:265`), the reader CSS (`BodyFormatting.kt:54-56`), the splash/launcher assets.

Theme mode: `resolvesDark` (`Theme.kt:131-136`) honours the `AppTheme` preference (SYSTEM/LIGHT/DARK) for the Compose scheme and `LocalLogoTint`, but the reader WebView stylesheet uses `isSystemInDarkTheme()` directly (`MessageDetailScreen.kt:376`), so with the preference forced LIGHT on a dark system (or vice versa) the reader body and the chrome around it diverge.

### Name-to-colour mappings

Flag palette, `FlagPaletteSettings.kt:269-281` (`flagColor`), vocabulary from `FlagPalette.kt:44`:

| name | colour |
|---|---|
| red | `#D32F2F` |
| orange | `#F57C00` |
| yellow | `#F9A825` |
| green | `#388E3C` |
| teal | `#00897B` |
| blue | `#1976D2` |
| indigo | `#3949AB` |
| purple | `#8E24AA` |
| pink | `#D81B60` |
| gray (and any unknown name) | `#757575` |

Logo tint, `Theme.kt:160` / `values/logo.xml`: light → `logo_forest #2E5235`; dark → `logo_mint #8DC899`.

Sender avatar, `EnvelopeRow.kt:249,265`: `hue = address.hashCode().mod(360)`, `Color.hsv(hue, s = 0.35, v = 0.55)`; white initial on top. Not a named mapping; one colour per address string.

Reader mode CSS, `BodyFormatting.kt:54-56`: light fg `#1a1c1a` / bg `#fdfcf8` / link `#2e6b30`; dark fg `#e4e2dd` / bg `#121412` / link `#9ccc9c`.

There is no address-swatch name mapping ("ink", "oxblood", ...) on Android beyond the accent enum; those names only select the scheme seed.

## Counts

### Sites per colour value (literal or resolved)

| value | sites |
|---|---|
| `#2E5235` (logo_forest) | 8 — Theme.kt:45, Theme.kt:160 (light branch), logo.xml:4, themes.xml:9, ic_launcher_foreground.xml:14, :18, cabalmail_mark.xml:10, :14 |
| `#8DC899` (logo_mint) | 2 — Theme.kt:160 (dark branch), logo.xml:5 |
| `#1F2A44` (INK seed) | 1 |
| `#6B1F2A` (OXBLOOD seed) | 1 |
| `#1F5B3A` (FOREST seed) | 1 |
| `#1B5E9E` (AZURE seed) | 1 |
| `#B0651B` (AMBER seed) | 1 |
| `#5B2A6B` (PLUM seed) | 1 |
| `#10141A` (dark onPrimary) | 1 |
| `Color.White` | 3 — Theme.kt:108, FlagPaletteSettings.kt:245, EnvelopeRow.kt:270 |
| `#D32F2F` red | 1 |
| `#F57C00` orange | 1 |
| `#F9A825` yellow | 1 |
| `#388E3C` green | 1 |
| `#00897B` teal | 1 |
| `#1976D2` blue | 1 |
| `#3949AB` indigo | 1 |
| `#8E24AA` purple | 1 |
| `#D81B60` pink | 1 |
| `#757575` gray/unknown | 1 |
| `flagColor(...)` applied (any of the above) | 7 — FlagPaletteSettings.kt:235, MessageDetailScreen.kt:266, :552, MessageListScreen.kt:673, EnvelopeRow.kt:192, RuleEditorScreen.kt:465/637 (1), plus the default pick at FlagPaletteSettings.kt:114 |
| `Color.hsv(hue, 0.35, 0.55)` | 1 |
| `#FAF4E4` | 1 |
| `#EFE2C0` | 1 |
| `#1a1c1a` / `#e4e2dd` (reader fg) | 2 sites (:54 chosen, :66 applied) |
| `#fdfcf8` / `#121412` (reader bg) | 3 sites (:55 chosen, :61 and :66 applied) |
| `#2e6b30` / `#9ccc9c` (reader link) | 2 sites (:56 chosen, :74 applied) |
| `cs.primary` | 15 — Theme.kt:96, :107 (definitions); SignInScreen.kt:76, MessageListScreen.kt:596, FolderListScreen.kt:295, :301, :322, PlainTextLinks.kt:104, EnvelopeRow.kt:114, RecipientField.kt:136, RuleEditorScreen.kt:170, ComposeScreen.kt:187, :428, plus MessageListScreen.kt:618 (re-applied wash) |
| `cs.error` | 28 — DisposeSplitButton.kt:81, MessageDetailScreen.kt:335, MessageListScreen.kt:254, :730, FolderListScreen.kt:188, :235, :346 (Badge default), :353, EnvelopeRow.kt:159, :167, SearchScreen.kt:102, NewAddressSheet.kt:151, RulesScreen.kt:144, :279, RuleEditorScreen.kt:183, ComposeScreen.kt:316, :516, :522, AddressesScreen.kt:162, :259, FoldersAdminScreen.kt:138, :178, SettingsScreen.kt:281, SignInScreen.kt:183, FlagPaletteSettings.kt:193, :210 |
| `cs.errorContainer` | 5 — MessageDetailScreen.kt:611, EnvelopeRow.kt:372, CabalmailNavHost.kt:340, AddressesScreen.kt:202, (+ EnvelopeRow.kt:381 drawn over it) |
| `cs.onErrorContainer` | 3 — MessageDetailScreen.kt:614 (implicit), CabalmailNavHost.kt:341, AddressesScreen.kt:208 |
| `cs.secondaryContainer` | 7 — Theme.kt:101, :112 (definitions); SettingsScreen.kt:179, MessageDetailScreen.kt:609, FolderListScreen.kt:330, EnvelopeRow.kt:366 |
| `cs.onSecondaryContainer` | 3 — Theme.kt:102, :113 (definitions); MessageDetailScreen.kt:614 (implicit) |
| `cs.tertiary` | 7 — Theme.kt:103, :114 (definitions); MessageDetailScreen.kt:229, EnvelopeRow.kt:176, ComposeScreen.kt:402, AddressesScreen.kt:237 |
| `cs.inversePrimary` (snackbar action) | 1 — CabalmailNavHost.kt:324 |
| `cs.secondary`, `cs.primaryContainer`, `cs.onPrimaryContainer`, `cs.onPrimary` | defined at Theme.kt:97-113 only; no direct app use (consumed by M3 component defaults) |
| dynamic scheme | 2 — Theme.kt:153, :154 |

### Sites per role (table rows)

| role | app | kit | resources | total |
|---|---|---|---|---|
| scheme-seed | 22 | 2 | 0 | 24 |
| user-data | 11 | 11 | 0 | 22 |
| text-fg | 28 | 3 | 0 | 31 |
| text-fg + fill | 0 | 1 | 0 | 1 |
| glyph-fg | 10 | 0 | 4 | 14 |
| fill | 17 | 2 | 3 | 22 |
| fill + on-fill (Badge) | 1 | 0 | 0 | 1 |
| on-fill | 8 | 0 | 0 | 8 |
| wash | 1 | 0 | 0 | 1 |
| control-tint | 5 | 0 | 0 | 5 |
| brand | 2 | 0 | 2 | 4 |
| border/stroke | 0 | 0 | 0 | 0 |
| shadow | 0 | 0 | 0 | 0 |
| **total rows** | **105** | **19** | **9** | **133** |

### Sites per meaning (table rows, first-listed meaning)

| meaning | app | kit | resources | total |
|---|---|---|---|---|
| accent (incl. scheme definitions, wire/persistence) | 26 | 12 | 0 | 38 |
| user-flag-colour | 17 | 1 | 0 | 18 |
| danger/destructive | 15 | 0 | 0 | 15 |
| brand/logo (incl. brand app title) | 4 | 0 | 9 | 13 |
| error-state | 9 | 0 | 0 | 9 |
| selected | 7 | 0 | 0 | 7 |
| flagged (incl. favourite) | 6 | 0 | 0 | 6 |
| other | 4 | 4 | 0 | 8 |
| warning | 4 | 0 | 0 | 4 |
| info | 4 | 0 | 0 | 4 |
| link | 1 | 2 | 0 | 3 |
| success | 2 | 0 | 0 | 2 |
| auth-bad | 2 | 0 | 0 | 2 |
| unread | 2 | 0 | 0 | 2 |
| address-swatch | 2 | 0 | 0 | 2 |

No site in scope carries a comment citing a contrast measurement or an issue/PR number about colour; every "measured?" cell is "no".
