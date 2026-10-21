# Unified flags and cross-media Phases 2, 4, 5 and 6

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session, as a chain of five sessions rather than a project. Each phase already has one batch of decisions, three or four sequential PRs and one release, and its gates sit in other plans, so a standing coordinator would wait for weeks between phases; the plan docs' Progress tables let each session start cold.
**Size:** XL overall. Stage A (unified flags) M; Phase 2 L; Phase 4 M to L; Phase 5 structure M; Phase 5 views M to L; Phase 6 S.
**Priority:** Next for Stage A, after the Duo round and after feed-bulk-actions.md. Later for the cross-media sessions. No open issue asks for any of it, bugs go first by the maintainer's standing rule, and the feed files are held first by feed-bulk-actions.md and sqlite-mail-store.md Phase 0. Stage A's server PR (A1) can merge at any time.
**Depends on:** feed-bulk-actions.md (it finishes before Stage A's app PRs), ipad-layout-and-keyboard.md (its PRs A, C and F before A3), docs-and-bookkeeping.md (the API rule in the repo and Phase 1's status, before A0), sqlite-mail-store.md (PR 0.2 before B2.3; PR 5.1 before B5.2), multi-window-and-restore.md (W4 for #2016 before B2.4, or B2.4 takes it on), shared-load-error-state.md (A3 for #1903 before B4.3), platform-conditionals.md (its Rules PRs before B4.3), mail-navigation-refactors.md (PR 1 before B5.1).
**Unblocks:** android-parity.md (its legs L1 to L4 follow each Apple leg here), detached-reader-window.md (feed items in a window, through B5.1's two-case item identity).
**Duo groundwork:** B5.1's one sidebar selection and two-case item identity are what the feeds audit of 2026-10-02 names as the hosts for a spanned layout and a detached feed reader (see "Background from the rearchitecture"); Stage A and Phase 2 change the reader's Flag control, which folds early on the Duo's vertical bar, so both get a Studio Duo simulator pass and Stage A a physical-Duo row on the maintainer's checklist.
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
|---|---|
| Decisions 1 to 9 | None answered (2026-10-15); 1 to 3 are needed before Stage A. |
| Session 1: Stage A, unified flags (A0 to A4) | Not started (2026-10-15). |
| Session 2: Phase 2, custom flags on feed items (B2.1 to B2.4) | Not started (2026-10-15). |
| Session 3: Phase 4, feed rules (B4.1 to B4.3) | Not started (2026-10-15). |
| Session 4: Phase 5 structure, then Phase 6 (B5.1, B6.1) | Not started (2026-10-15). |
| Session 5: Phase 5 views (B5.2, B5.3) | Not started (2026-10-15). |

> **Duo spec (2026-10-13):** This plan was written before the maintainer's Oct 7 Duo spec (the Claude Doc linked in duo-support.md) had been read. duo-support.md now follows it; where this plan's text disagrees with the points below, the points win. In the spec, "fold" means book or laptop pose, which changes no size class and swaps no shell; what this plan calls folding or unfolding the Duo is closing or opening it.
>
> - B5.1's single iOS sidebar list across both media waits on duo-support.md Decision 9: under one tree, Feeds is a tab of its own on iPad and the Duo. Limit B5.1's one list to the Mac (and visionOS) until then, and ask where Flagged lives on iOS as a Phase 5 decision.
> - Stage A's and Phase 2's Duo passes add open portrait and laptop, where Flag sits in a bottom toolbar below the fold, and book pose. Build the Flag menu on a value both a top bar and a bottom toolbar can mount.

## Decisions for the maintainer

### Answer now (before Stage A)

1. **Sessions or a project for this work?** **Sessions (recommended)**: Stage A now as one session, then one session per cross-media phase, each opened when its gate below clears. Project: one coordinator for Phases 2 to 6 with a server thread a phase ahead; worth it only if you want Phases 2 and 4 to run back to back. Default: sessions.
2. **The feed's Flag button after unified flags: Follows the palette or Fixed?** **Follows the palette (recommended)**: the feed's existing flag (stored as `is_favorite`) takes the name and colour of the palette's Flagged entry and hides when that entry is disabled; once Phase 2 gives feed items custom flags, the feed swipe and ⇧⌘8 toggle the default flag, as mail's do. Fixed: the feed keeps a "Flagged" toggle whatever the palette says. Neither changes the server. Default: Follows the palette.
3. **Android legs: android-parity.md or here?** **android-parity.md (recommended)**: each Android leg runs as one short session after its Apple leg is promoted (android-parity.md decision 6), so Android runs about a release behind. This changes the cross-media plan's rule that "Apple and Android are the reference clients and ship together per phase" (`cross-media-ux-plan.md:52-53`). Your words, "leave it for now and revisit in another project that isn't dedicated to the Apple clients" (the maintainer, answering the sticky feed order plan's Android question with "Android: yes, with caveats..."), were about Android feed order; this extends them. Server changes stay additive, so shipped Android keeps working, and until its leg ships it shows an edited Flagged entry as one more custom flag. Here: each phase waits for its Android half. Default: android-parity.md.

### Due later (each asked again in its phase's scope doc)

4. **(Phase 2) Per-flag filtering.** The cross-media plan assumes a per-flag mail filter that does not exist (`MessageFilter.swift:8-11`). **(a) Both lists, per visit (recommended)**: an optional `keyword` on the server's message search, a device query for feeds, and one flag picker inside the Flagged pill rather than a pill per flag (#2014 shows the pill row already wraps at 322 pt); the pick resets when you leave the list. (b) Both lists, sticky: also new filter values on `set_preferences` and the feed's `default_filter`, promoted before the client, since an unknown value rejects the whole settings push (`set_preferences/function.py:61-75, 222-235`). (c) Feeds only. (d) Neither yet. Default: (a).
5. **(Phase 2) When the feed store's schema 7 ships: Before the shared queue or After?** **Before (recommended)**: after sqlite-mail-store.md's PR 0.2 (the #1956 and #1957 feed-store fix, in its Phase 0 session) and before its Phase 4 reaches the feed store. That plan accepts this window (in its design rules, after the downgrade-drill table): an older build that has PR 0.2 sets a schema 7 file aside, the newer build recovers its unsent feed marks when it returns, and its PR 4.5 later moves the flag rows into the shared queue. Only a build from before PR 0.2 (1.31.0 and earlier) still deletes the file and its unsent marks. After: Phase 2 waits for sqlite Phase 4's second release, several releases later, and flag changes go straight into the shared queue. Default: Before.

   > **Erratum (2026-10-15):** 1.31.1 and 1.31.2 have shipped since this was written, and neither carries sqlite-mail-store.md's PR 0.2 (not started), so every build through 1.31.2 still deletes a schema 7 file and its unsent marks.

6. **(Phase 4) Where feed rules are stored.** **(a) Beside (recommended)**: a `feedRules` list next to `rules` in the same row, under the same version. One editor, one version; shipped apps never see a feed rule, a save from one rewrites only `rules` (`set_rules/function.py:317-323`), and the procmail compiler is untouched. (b) Inside `rules` with a `source` field, as the plan says: once one feed rule exists, every shipped Apple and Android build can no longer read or edit any rule (the pane shows "Couldn't load rules"), because both decoders reject an unknown condition field by design (`Rule.swift:11-15`, `Rules.kt`; #1901 open). (c) A separate table and endpoints. Default: (a).
7. **(Phase 5) When the Flagged view is built: Wait or Now?** **Wait (recommended)**: built once on sqlite-mail-store.md's PR 5.1 (a cross-folder flagged query in its last phase), which fills from the server's flagged search while online and keeps it for offline; mail and feed rows interleave by date as planned. Now: the mail half calls the server's cross-folder `flagged=1` search directly, online only, in two sections by medium, and is rebuilt when PR 5.1 lands. Default: Wait.
8. **(Phase 5) The All / Mail / Feeds search scope: Keep or Drop?** Your two recorded positions disagree, and nothing new has happened since the later one. `rss-requirements.md:576-577` (revised Decision 14) says "cross-feed FTS is not a real-world need"; the cross-media plan, added on 2026-09-23 (commit 9370b69f), cites that decision and still includes this scope as a device-side search ("Neither needs a server change", `cross-media-ux-plan.md:202`; Phase 5 item 2 at `:414-420`). **Keep (recommended)**: it is in your later plan, costs no server work, and is Phase 5's last PR, so dropping it then costs nothing. Drop: search stays mail-only. Default: Keep.
9. **(Phase 6) Feed notification switches before feeds can notify: Wait or Now?** **Wait (recommended)**, which reverses the cross-media plan's "rather than hiding the toggle" (`:440-442`). What is new: mail's notification choices are per device, kept on this device's push-token row (`NotificationSettingsSection.swift`, the type comment), while a feed's switch is per subscription and synced, so "the same shape" mixes two kinds of switch in one list; the section is not built on visionOS at all (`:1-4`); and the file carries nine allowlisted `#if` blocks the ratchet only lets shrink. Delivery is RSS plan Phase 8, not started. Now: a feed section with a "not yet delivered" note. Default: Wait; Phase 6 is Spotlight alone.

Not asked again: keyword mute ("No per-feed keyword muting", `rss-requirements.md:570`); Favorite becoming Flag (shipped in 1.22.0); server-side cross-feed search (`rss-requirements.md:573-581`); the React and Linux clients (non-goals in both plans); unified flags before Phase 2 (1.5 decision 12: "doing it now means doing it twice").

## What you'll see change

- **A0 (docs):** nothing visible. The two plan docs stop contradicting the code, so each later session starts from facts.
- **A1 (server):** nothing visible. Settings can store the system flag as a palette entry.
- **A2 (Kit):** nothing visible.
- **A3 (rendering):** mail's flag glyph becomes a coloured dot on rows and a chip in the reader; feed rows draw the same small dot inline instead of the large trailing flag; both lists draw one unread dot. "Flagged" is the first row of Settings > Flags, and you can rename, recolour, reorder or disable it; "Reset to default" replaces Delete on it.
- **A4 (affordances):** the first enabled flag wears a "Default" badge and other rows offer "Make default"; swipe, ⇧⌘8, ⇧⌘L, the bulk bars and the row menus toggle it, and their labels and the Flagged pill follow its name; disabling every flag hides the swipe and greys the shortcut. The feed's Flag button takes the Flagged entry's name and colour (decision 2).
- **Phase 2:** custom flags apply to feed items from the reader's Flag menu, the row menu and the bulk bar, sync across devices, and filter the lists (decision 4).
- **Phase 4:** Settings > Rules gains a "Feed items" section; a feed rule flags or marks read a new item when it is fetched, before any device opens the feed.
- **Phase 5 structure (B5.1):** feed rows in the wide sidebar select like folders, including with the arrow keys *(inferred)*.
- **Phase 5 views (B5.2, B5.3):** a "Flagged" sidebar entry lists flagged mail and flagged feed items together, each opening in its own reader; under decision 8, search gains All, Mail and Feeds.
- **Phase 6:** feed item titles appear in Spotlight and open the item.

## Why

- **Two flag vocabularies.** The system `\Flagged` toggle and the 20-slot palette have separate settings, renderings and gestures, "an artefact of implementation order, not a user-facing concept" (`docs/1.x/unified-flags-plan.md:30-31`).
- **Feeds are second-class for flags and rules.** A user's "Read later" flag cannot be applied to an article, and rules exist only for mail (`cross-media-ux-plan.md:31-50`).
- **Row drift, deferred on purpose.** The feed row's flag is body-size at the trailing edge while mail's is caption-size inline (the feeds audit's F8, chrome drift between media). 1.5 left the unread dot and flag mark out of the chrome kit because "the unified-flags plan will restyle the flag glyph, so doing it now means doing it twice" (Wave 1.5's scope doc, decision 12).
- **The plans aged under the rearchitecture.** The rearchitecture proposal noted that both plans were still live and let cross-media Phase 2 and the unified-flags plan run alongside waves 0 and 1. Neither ran, and the waves changed the code beneath them.

## Where things stand

In short: cross-media Phase 1 shipped but its plan still says "In review"; every other phase of both plans is "Not started"; the waves left generic selection, `MessageRef` and a chrome kit, but no two-case item identity, no one-selection sidebar and no feed deep link; and several plan assumptions about the server and the shipped decoders are false.

**Plan status.**
- Cross-media Phase 1 shipped on both clients in 1.22.0 (2026-09-25): Favorite became Flag, feed badges follow Folder counts, `/mark_folder_read`, the Feeds menu chords and the feed scope switcher (`CHANGELOG.md:1083-1190`), plus the #1706 fix (closed). Its Progress row and Status still say "In review (2026-09-24)" (`cross-media-ux-plan.md:11, 215-223`). No stage or device verification of Phase 1 is recorded; the Wave 3 TestFlight checklist's unchecked "Mark All as Read in the front window" item tests PR #1999, not Phase 1.
- Cross-media Phases 2 to 6 and all five unified-flags phases are "Not started" (`cross-media-ux-plan.md:12-16`; `unified-flags-plan.md:5-11`). The unified-flags plan's only later edit is the 2026-10-11 erratum for #2019 (closed): the Mac reorders flags with Move Up and Move Down (`:291-295`). The cross-media plan was last edited 2026-09-24 (610d4e22).

**What the rearchitecture changed underneath.**
- `SelectionModel<ID>` is generic and per window (`Shared/Primitives/SelectionModel.swift:15`; `SceneNavigator.swift:695`), but only mail uses it; feeds still select one `RssItem?` (`FeedItemListView.swift:10, 200`). feed-bulk-actions.md adopts it for feeds.
- `MessageRef` is mail identity (`Models/MessageRef.swift:27`). There is no two-case `ItemRef`; `AppRoute` keeps separate mail and feed halves (`Navigation/AppRoute.swift:16-20`). The feeds audit's `MediumItemRef` sketch (`case mail(folder: String, uid: UInt32, messageID: String?)` and `case feed(RssItem.ID)`; see "Background from the rearchitecture") predates `MessageRef` and should become `case mail(MessageRef)`.
- The chrome kit (`Shared/Chrome/`) has no unread dot or flag mark. Mail draws its dot at `MessageListView+Rows.swift:414-417` and its flag glyph and keyword dots at `:469-486`; feeds draw theirs at `FeedItemListView.swift:304-308, 337-341`.
- `RssStore` is at schema 6 (`RssStore.swift:35`). Its `pending` table holds one Bool per row (`:469-472`), coalesced per kind and item (`RssStore+State.swift:164-171`). `openRecovering` deletes a newer-schema file (`RssStore.swift:78-87`) until sqlite-mail-store.md's PR 0.2 changes that.
- Flag commands go through `FocusedValue`: `WindowCommand.toggleFlagged` (`Commands/WindowCommands.swift:12`), ⇧⌘8 at `MessageMenuCommands.swift:53-54`, answered in the list at `MessageListView.swift:552`; the reader's ⇧⌘L is a chord host (`MessageDetailView+ChordHosts.swift:27-28`).
- `MailRootView` is gone (3.2 E, ede7b269). `SignedInRootView` (`Shell/SignedInRootView.swift:32`) switches between the four shells and holds the window's `SceneNavigator` above the switch. The wide sidebar is the mail folder `List` built in `Mail/Folders/FolderListView+Helpers.swift`, hosted by `Shell/WideMail.swift`, with feeds drawn as buttons inside it (`.rowButtons`, `:100`; defined in `Feeds/Sidebar/FeedSidebarContent.swift:16-21`) because one `List` carries one selection type. 2.3 expected a one-selection sidebar in 3.2; it did not land.
- `DeepLinkRouter` has message, Spotlight and folder links and no feed link (`Navigation/DeepLinkRouter.swift:6-14`). `SpotlightIndexer` indexes envelopes and bodies only (`Spotlight/SpotlightIndexer.swift:132, 159`).
- `MailMutationService.setFlag` (`Mail/Store/MailMutationService.swift:117`) takes any flag, so a keyword default flag needs no new write path. The feed reader's Flag button is one plain button in one toolbar slot (`FeedReaderToolbar.swift:72-80`; `FeedReaderToolbarLayout.swift:7`).

**Server and storage facts.**
- `set_preferences` allows only `cabal-flag-01..20` and at most 20 entries (`set_preferences/function.py:103, 152`), and rejects the whole `app` map on any invalid value (`:180-214`). Its palette validator has no unit tests; `test_set_preferences_app_map.py` covers filters, orders and swipes, and the suites run under stdlib `unittest` (`lint.yml:279`). `set_flag` already accepts `\Flagged` (`set_flag/function.py:51-54`).
- `rss_set_item_state` writes `is_read` and `is_favorite` only. An entry with neither returns `('', {})` and is skipped, and the call still answers 200 (`rss_set_item_state/function.py:34-40, 55-82`).
- `search_envelopes` searches every subscribed folder but Trash when `folder` is omitted and accepts `flagged=1`, with no keyword criterion (`search_envelopes/function.py:9-13, 151-188`).
- `set_rules` rejects unknown rule keys (`set_rules/function.py:234-236`) and writes only `rules`, `version` and `updatedAt` (`:317-323`). The compiler reads only `rules` (`docker/shared/compile-user-rules.py:615`).
- `rss_fetch` has no subscriber lookup (`rss_fetch/function.py:286-326`). The subscription table's only feed-keyed index is the sparse `by_feed_notify` (`terraform/infra/modules/table/main.tf:445`). Its IAM role reaches only the feed and item tables, the S3 `items/` prefix, its queue, SSM and its logs (`terraform/infra/modules/app/rss_fetcher.tf:194-262`): not the rules, subscription or item-state tables.
- `app.yml` redeploys every changed `lambda/api` function on a push, independently of `infra.yml` (`app.yml:670-690`), so Lambda code can reach prod before the Terraform it needs.
- Android: Room is at version 1 with a destructive fallback (`RoomRssStore.kt:355-366`); its API decoder ignores unknown keys (`ApiClient.kt:105`).

**Issues (checked on GitHub 2026-10-12).** None is owned here. Open: #1901 and #1903 (shared-load-error-state.md), #1914 (feed-bulk-actions.md), #1956 and #1957 (sqlite-mail-store.md), #1962 (duo-support.md), #2014 and #2024 (ipad-layout-and-keyboard.md), #2016 and #2039 (multi-window-and-restore.md), #2022, #2031 and #2040 (Rules editor; #2031 and #2040 in platform-conditionals.md). Closed: #1706, #2019.

## The plan

### Rules for every session

1. **Server first, to prod.** A server PR merges and is promoted to prod before a client PR that relies on it merges to stage, because a TestFlight build from stage talks to prod (server #1919 shipped in 1.29.0 before client #1959 merged; sqlite-mail-store.md rule 6). The working agreements' "before or with" is too weak here, because each failure is silent: an old prod `set_preferences` rejects the whole settings push that carries a Flagged entry; an old prod `rss_set_item_state` answers 200 to an `add_flags`-only item, so the drain deletes the queued mark; an old prod `search_envelopes` ignores `keyword`, so the per-flag pill shows unfiltered mail. Server PRs are small, so each rides whatever release comes next and the client work rarely waits a full release.
2. **One open Apple PR at a time** from this plan, and one per hotspot (table below).
3. **Docs in the same PRs.** Each PR updates its phase's Progress row and Status line in `unified-flags-plan.md` or `cross-media-ux-plan.md`. Each phase's last PR updates `docs/user_manual.md`, and `docs/rss.md` or `docs/mail-rules.md` where they apply. Each phase's first PR records that phase's decisions as dated errata.
4. **Changelog.** Apple PRs carry `Apple:` fragments; server PRs carry a plain `added` fragment (the Apple gate does not apply).
5. **Source scans are asked up front, never edited to pass.** Stage A expects no scan edit. Phase 4 and B5.1 name theirs below; each asks the maintainer in its scope doc.
6. **Verification lanes.** CI on every PR; on the Mini, the macOS, iPad, iPhone and visionOS simulators with stage test account 1 (credentials read at run time from AWS Parameter Store by a helper on the rig; never print them); the Studio's Duo simulator where named; device checks on the maintainer's checklist, holding Promote, not merge.

   > **Erratum (2026-10-16):** The rig's credential helper serves test accounts 2 and 3, not test account 1. The rigs' simulators and Mac app are already signed in as test account 1; do not sign it out without asking the maintainer how to restore it (00-working-agreements.md, "Stage test accounts"). "The maintainer's checklist" means `needs-verification` issues, as that file's "Working from the repo" says.

### Session 1: Stage A, unified flags (one release)

**Status:** Not started (2026-10-15).

Scope: `unified-flags-plan.md` Phases 1, 2, 3 and 5 on Apple and the server, plus the shared row parts 1.5 deferred. Android (its Phase 4) goes to android-parity.md leg L1 (decision 3).

- **A0 Docs** (`no-changelog`). Fact errata and decisions 1 to 3 only, from the drift list below. Check that docs-and-bookkeeping.md PR 2 has marked cross-media Phase 1 shipped; do it here only if it has not.
- **A1 Server** (plain `added` fragment). `set_preferences`: `\Flagged` joins `FLAG_PALETTE_SLOTS`; the cap becomes 21, with a comment tying it to "20 keyword slots plus the system flag". These are the first `_validate_flag_palette` tests: in `lambda/api/_shared/tests/test_set_preferences_app_map.py` (stdlib `unittest`), the slot round-trips, 22 entries reject, `cabal-flag-00` still rejects. Pylint per CLAUDE.md. The edit also runs `linux.yml` (`linux/xtask/tests/support/mod.rs:26`); the key list does not change. It can merge now and ride the next release. Risk low.
- **A2 Kit** (`no-changelog`). In `CabalmailKit/Settings/FlagPalette.swift`: `systemSlot`, `maxEntries` 21, `effective(_:)`, `defaultEntry(in:)`, `slots(in:)` in palette order including `\Flagged`, and the encode rule (write the entry only when edited or already on the wire). Tests in `FlagPaletteTests.swift` per `unified-flags-plan.md:276-280`. Risk low.
- **A3 Rendering** (`Apple:` changed, "One flags list"). Merges only after A1 is in prod. New `UnreadDot` and `FlagDots` in `Shared/Chrome/`, used by the mail and feed rows; `\Flagged` drawn as a palette-coloured dot and chip; the reader flag button in the default flag's colour; Settings > Flags lists the system entry with rename, recolour, disable and "Reset to default", and it joins Move Up and Move Down (every platform) and edit-mode drag (iOS and visionOS) (`FlagPaletteSettingsView.swift:10-12`). The feed row's dot comes from `is_favorite` (decision 2). `MessageListView+Rows.swift` has 586 raw lines and about 400 that SwiftLint counts, under the 500 warning. App-layer tests for the row inputs. Risk medium.
- **A4 Affordances** (same fragment, or one more line). The Default badge and "Make default", so the concept lands with its effect. Swipe `toggle_flag`, `WindowCommand.toggleFlagged`, the ⇧⌘L host, row menus, both bulk bars (`bulk.toggleFlag`; the feed bar from feed-bulk-actions.md) and `MessageDetailViewModel+Flags.swift` toggle the default flag; the flag menu's builder (`FlagMenuPolicy`) lists the system entry first; the pill, search toggle and swipe picker labels follow the palette; the no-default case hides and greys; the rule editor's Flagged row takes the palette style; the feed's Flag button, swipe and pill take the Flagged entry's name. User docs: `docs/user_manual.md` and `docs/mail-rules.md` per `unified-flags-plan.md:337-342`. Tester identifiers (`reader.toggleFlag`, `message.swipe.toggleFlag`, `bulk.toggleFlag`, `feed.swipe.toggleFavorite`) stay. Risk medium.

Release: one. Promote waits for A4, so the badge never ships without the retargeted gestures. Verify: the acceptance script at `unified-flags-plan.md:309-313` on macOS, iPad, iPhone and visionOS; the old-build checks under Risks; one Studio Duo simulator pass (swipe folded, reader chip and button unfolded); a physical-Duo row on the maintainer's checklist, since the device ships about 2026-10-23.

**Plan-doc drift A0 fixes** (dated errata after the falsified paragraph, never rewriting it; CLAUDE.md "Docs convention"):
1. `cross-media-ux-plan.md:306-311, 467`: schema 5 is schema 7 (the store is at 6). The Android leg is Room version 3, on android-parity.md PR 9's path; PR 9 writes this erratum's Android half (Room version 2, the sticky feed order plan's PR 4 follow-up: folder and All Feeds order on Android, which needs a real Room migration so queued read and flag marks are not dropped).
2. `:326-327`: "the per-flag filter the mail list offers" does not exist (`MessageFilter.swift:8-11`; `unified-flags-plan.md:71-74`). Decision 4 is recorded in Phase 2's first PR.
3. `:146-158, 371-378`: "so the shipped clients keep parsing" is false once one feed rule exists (Server facts). `rss_fetch` needs a subscriber lookup and IAM grants it does not have. Decision 6 is recorded in Phase 4's first PR.
4. `:408-413`: `MailRootView` is gone (3.2 E); `SignedInRootView` picks one of four shells and holds `SceneNavigator`; the Flagged entry joins the mail folder `List` in `FolderListView+Helpers.swift`, hosted by `WideMail.swift`.
5. `:443-447`: `SpotlightRouting` is a file (`Navigation/SpotlightRouting.swift`, an `AppState` extension), not a type, and it routes through `DeepLinkRouter`; a feed Spotlight result needs a feed link there.
6. `:52-53`: decision 3 (Android legs ship separately).
7. `unified-flags-plan.md:169-171, 349-352`: feed favourites have been flags since 1.22.0 and draw mail's glyph and colour (`FeedItemListView.swift:337-341`). Record decision 2.
8. `unified-flags-plan.md:162-167, 300`: on Apple the mark is `flag.fill`, not a star; `AppState.requestToggleFlagged` is now `WindowCommand.toggleFlagged`; client PRs merge after Phase 1 is in prod, not only "live on stage" (`:235, 258`).

> **Erratum (2026-10-20):** Items 1 to 6, and Phase 1's status, were folded into `cross-media-ux-plan.md` on 2026-10-20 as in-place rewrites against `stage` at d6d36148, not as dated errata: that plan still has phases to ship, and such a plan is corrected in place. It now writes each open decision to its default and lists them under "Open decisions". A0 is left with items 7 and 8 and recording decisions 1 to 3; where an answer differs from the default, A0 rewrites the affected text of the cross-media plan in place.

(Phase 3's stale `bulkMode` text at `cross-media-ux-plan.md:344-349` belongs to feed-bulk-actions.md.)

### Session 2: Phase 2, custom flags on feed items (one release; server PRs ride the one before)

**Status:** Not started (2026-10-15).

- **B2.1 Server.** `rss_set_item_state` accepts `add_flags` and `remove_flags` per item: DynamoDB `ADD` and `DELETE` on a string set; reject a slot in both lists; setting needs an enabled palette slot and clearing is always allowed, as `set_flag`'s `_check_keyword` does. `rss_api.serialize_item` and `serialize_state` emit sorted `flags`. `docs/rss.md`. Tests beside `test_rss_api_items.py`.
- **B2.2 Server (decision 4a or 4b).** `search_envelopes` takes an optional `keyword`, checked against the slot pattern and mapped to IMAP `KEYWORD`. Tests. Under 4b, the new filter values ride here too.
- **B2.3 Kit.** `RssItem.flags`; add and remove on the state change. Schema 7 on sqlite-mail-store.md PR 0.1's migration runner: an `items.flags` JSON column and a `pending.slot` column, with a `flag` kind whose value means add or remove, coalesced per item and slot so the latest intent wins (an add then a remove leaves a remove). `applyServerStates` skips a slot with a queued change. The drain sends at most 100 items a call. Every write shares a transaction with its queue row, as PR 0.2 makes the existing ones. Extend PR 0.2's set-aside import to key on item, kind and slot, so a downgrade and return keeps flag marks. Tests: 6 to 7 migration, coalescing, two devices merging slot 3 and slot 5 against a fake server, server states never overwriting a queued slot, a set-aside schema 7 file whose slot rows come back.
- **B2.4 Apple** (`Apple:` added). Merges only after B2.1 and B2.2 are in prod. The flag menu's builder moves from `Mail/Reader/` to `Shared/` over a small "flaggable" value (current slots, add, remove) and mounts on the feed reader's Flag button (a menu with a primary action, as mail's is) and the feed row menu. Feed rows draw slot dots through `FlagDots`. The feed toggle follows the default flag (decision 2). The per-flag picker on the Flagged pill (decision 4). Set flags joins the feed bulk bar. If multi-window-and-restore.md's W4 (#2016) has not landed, this PR changes the greyed feed stand-in (`Feeds/Reader/EmptyFeedDetailToolbar.swift`) to match the new menu, or the Mac toolbar jump gets worse. User docs.

Verify: Kit and Lambda tests; on the Mini, the acceptance at `cross-media-ux-plan.md:331-335`, and sqlite-mail-store.md's downgrade drill with an offline feed flag; a Studio Duo simulator pass for the reader's Flag menu on the vertical bar, which "folds far sooner" (`FeedReaderToolbar.swift:25-31`). The two-device check is under Risks.

### Session 3: Phase 4, feed rules (one release; Terraform and server ride earlier ones)

**Status:** Not started (2026-10-15).

- **B4.1 Terraform** (rides an earlier promotion, for example Phase 2's). The subscriber lookup and the grants `rss_fetch` lacks: read on `cabal-user-rules`, query on the new subscription index, update on `cabal-rss-user-item-state`. The index shape is a Phase 4 scope question: a plain feed-keyed index (simple; one rules read per subscriber per fetch that inserts items) or a sparse one that `set_rules` must maintain *(inferred: plain is enough at hobby scale)*. Through `infra.yml` with Checkov, tflint and tfsec.
- **B4.2 Server** (decision 6a). `get_rules` returns `feedRules`; `set_rules` accepts it as an optional field under the same version check and validates it (conditions `feed`, `title`, `author`, `summary`; actions `flags`, `markRead`). `rss_fetch` evaluates each subscriber's feed rules at `insert_item` and writes `flags` and an explicit `is_read` to their state rows, best effort: a rules lookup failure logs and never fails ingestion or dead-letters a feed. Metrics per feed. `docs/mail-rules.md` "Feed rules"; `docs/rss.md` notes ingest-time evaluation. Promoted before B4.3 merges.
- **B4.3 Kit and Apple** (`Apple:` added). A feed rule model and validator; a "Feed items" section in Settings > Rules inside the same grouped `Form`; a "Flag matching items" template beside `muteNewsletter`. Scans to ask about first: `RulesPaneContainerSourceScanTests` and `RuleRowHitTargetTests` (`RulesView.swift`), `SectionFooterWrapTests` (`RulesView.swift`, `RuleEditorView.swift`, `RuleEditorExtras.swift`).

Verify: on stage, a synthetic check before Promote: one feed with many subscribers that have feed rules (fixture subscription and rules rows for made-up stage users, removed afterwards), measuring reads and duration per fetch invocation, since stage's real subscriber counts are too small to show the cost *(inferred harness; the session picks it)*. On the Mini, the acceptance at `cross-media-ux-plan.md:400-402`, and a save from the 1.31.0 build leaving `feedRules` intact. android-parity.md checks the same for Android before its leg L3.

### Session 4: Phase 5 structure, then Phase 6 (two releases)

**Status:** Not started (2026-10-15).

Needs nothing from Phases 2 or 4, so it can run as soon as its gate clears; by default it follows Session 3.

- **B5.1 Structure** (`Apple:` changed, "Feeds select like folders"). `ItemRef` in the Kit (`.mail(MessageRef)`, `.feed(feedID:sortKey:)`), one identity for a message or a feed item. One sidebar selection (`.mailFolder`, `.feedScope`, `.smartView`) replaces the `.rowButtons` workaround, so one `List` selects both media. `AppRoute` gains the smart view and still decodes routes stored by older builds. Scans to ask about first: `AllFeedsRowSourceScanTests` (`FeedSidebarContent.swift`), `FolderSwitchPlacementTests.swift:91` (reads `FolderListView+Helpers.swift`), `CompactBrandMarkSourceScanTests` (`FeedSidebarSection.swift`). Risk high (root navigation; the feeds audit rates its matching workstream, WS-X5, high). Verify: the restore suites; Mini macOS, iPad and visionOS (`OrnamentShell` hosts the sidebar); a Studio Duo fold and unfold pass.
- **B6.1 Spotlight for feed items** (`Apple:` added; next release). `SpotlightIndexer` gains a feed-item path fed by `RssSyncEngine`, pruned with the cache and removed at sign-out; `DeepLinkRouter` gains a feed item link. Under decision 9 Now, the notification section joins here. Kit tests skip Spotlight's delete-all on iOS and visionOS simulators without a host app (`FeedStoreSignOutTests.swift:47-52`); check on the macOS build on the Mini first, then on a device.

### Session 5: Phase 5 views (one release)

**Status:** Not started (2026-10-15).

- **B5.2 Flagged view** (`Apple:` added). Flagged mail and feed items interleaved by date, each with its medium's glyph and opening in its own reader, a flag picker, and counts that follow the Reading preference. The mail half reads sqlite-mail-store.md's PR 5.1 query (decision 7).
- **B5.3 Search scope** (decision 8 Keep; `Apple:` added). A scope segment in global search and results sectioned by medium; the feed half widens `RssStore`'s FTS query from one subscription to all cached items. If mail-navigation-refactors.md built its global search model (its PR 7), this builds on it.

Verify: Mini lanes on all four platforms; a Studio Duo pass for the Flagged entry on both displays.

### Gates

| Gate | Before | Needs |
|---|---|---|
| G0 | A3 merges | Decisions 1 to 3; A1 in prod; feed-bulk-actions.md finished (it holds `Feeds/ItemList/*`, `FlagPaletteSettingsView.swift` and the shared bulk bar); ipad-layout-and-keyboard.md PRs A, C and F merged (rows, menu commands, `FilterPill.swift`); docs-and-bookkeeping.md PRs 1 and 2 merged (soft) |
| G1 | B2.3 merges | Stage A promoted; sqlite-mail-store.md PRs 0.1 and 0.2 merged and its Phase 4 not yet in `RSS/` (decision 5); decisions 4 and 5 |
| G2 | B2.4 merges | B2.1 and B2.2 in prod; multi-window-and-restore.md W4 merged, or B2.4 takes the feed stand-in |
| G3 | B4.3 merges | Phase 2 promoted; B4.1 and B4.2 in prod; decision 6; shared-load-error-state.md A3 (#1903) merged, since otherwise a garbled save reply turns the next edit into a false "Rules updated on another device"; platform-conditionals.md's Rules PRs (#2031, #2040) merged |
| G4 | B5.1 | mail-navigation-refactors.md PR 1 merged (`SceneNavigator.swift` is 728 lines); multi-window-and-restore.md session 1 not open in `AppRoute.swift`, `StoredRoute.swift` or `DeepLinkRouter.swift`; scan answers |
| G5 | B6.1 | B5.1 promoted; decision 9 |
| G6 | B5.2 | B5.1 and Phase 2 promoted; sqlite-mail-store.md PR 5.1 merged (decision 7 Wait); decisions 7 and 8 |

**Releases.** Six client releases, one structural change each: Stage A; Phase 2; Phase 4; B5.1; B6.1; Phase 5 views. The server PRs ride earlier releases. Soak on the Mini before each promotion. Calendar time is set mostly by the gates in other plans *(inferred)*.

**Hotspots.** One open PR at a time in each; the named plan goes first when both are ready.
- `Feeds/ItemList/*`, `Settings/FlagPaletteSettingsView.swift`, `MessageListView+Bulk.swift` and the shared bulk bar: feed-bulk-actions.md (PRs A to E).
- `Mail/MessageList/MessageListView+Rows.swift`: ipad-layout-and-keyboard.md (#2032). `Shared/Chrome/FilterPill.swift`, `MessageListView+Filter.swift`: ipad-layout-and-keyboard.md PR F (#2014). `Commands/MessageMenuCommands.swift`, `FeedsMenuCommands.swift`: its PR C (#2024).
- `MessageListView.swift`: multi-window-and-restore.md session 1. `EmptyFeedDetailToolbar.swift`: its W4.
- `MessageDetailViewModel+Flags.swift` and its family: mail-navigation-refactors.md, mail-correctness.md, detached-reader-window.md, shared-load-error-state.md B3, duo-support.md.
- `CabalmailKit/RSS/*`: sqlite-mail-store.md (Phase 0, then its Kit thread from Phase 4) and feed-bulk-actions.md PR B.
- `Rules/RulesView.swift`, `RulesViewModel.swift`: platform-conditionals.md, shared-load-error-state.md A6 and B1.
- `Navigation/SceneNavigator.swift`, `AppRoute.swift`, `DeepLinkRouter.swift`, the shells: mail-navigation-refactors.md, multi-window-and-restore.md, duo-support.md.

## Background from the rearchitecture

What this plan takes from Wave 1.5's scope doc and the feeds audit of 2026-10-02 (audit 02), which are not in the repo. "Where things stand" records what the waves changed since.

**Wave 1.5's decision 12 (Session 1).** Wave 1.5 built the chrome kit: one `FilterPill` for the mail list, the feed list and both sidebar filter rows; one `CountBadge` for folder and feed counts; one `SidebarTreeRowLabel` under folder and feed rows, with one tint rule and the visionOS hover; shared title-menu rows; and one reader toolbar policy for both readers. Its decision 12 left out the unread dot and the flag glyph (`UnreadDot` and `FlagMark`, the item-row part of the feeds audit's F8), because "the unified-flags plan will restyle the flag glyph, so doing it now means doing it twice". A3 adds them, as `UnreadDot` and `FlagDots`.

**The feeds audit's F8 (Session 1).** "List and sidebar chrome drifts between media (user-visible)": the two media drew their filter pills, sidebar badges, row tints and visionOS hover differently, and on item rows mail's flag glyph is `.font(.caption)` inline with the date while the feed's flag is body-size at the trailing edge. Severity low for each, medium together ("exactly the 'bolt-on' feeling the cross-media plan wants gone"). It recommended shared `FilterPill`, `CountBadge`, `SidebarTreeRowLabel`, `UnreadDot` and `FlagMark` views, plain view code with no generics beyond `@ViewBuilder`. Wave 1.5 built all but the last two.

**The feeds audit's row identity sketch (Sessions 4 and 5).** A medium-neutral row identity for cross-media views, "a value, not a protocol hierarchy", which the audit judged worth doing only when Phase 5 starts:

```swift
enum MediumItemRef: Hashable, Sendable {
    case mail(folder: String, uid: UInt32, messageID: String?)
    case feed(RssItem.ID)
}
struct ItemRowSummary: Identifiable, Hashable {   // what a mixed list needs to draw a row
    let id: MediumItemRef
    let title: String; let source: String; let date: Date?
    let isRead: Bool; let isFlagged: Bool
}
```

**The feeds audit's dual-screen groundwork (Sessions 4 and 5, and the Duo groundwork line above).** "Feeds in the wide sidebar are Button rows in mail's `List`" because one `List` has one selection type; a `SidebarSelection` enum (`.mailFolder(path)`, `.feedScope(scope)`, `.smartView(...)`) would give native selection and keyboard navigation to both, and is "the natural host for the Phase 5 Flagged view and for a 'spanned' two-pane layout where the sidebar lives on one screen". Reader and list are already independent views keyed by id, and the reader resolves its own subscription: "a good basis for 'list on screen A, reader on screen B' or an `openWindow(value: MediumItemRef)` detached reader", with `MediumItemRef` as the window value type.

**The feeds audit's WS-X5 (Session 4).** "Medium-neutral row and scene-scoped navigation", gated on cross-media Phase 5: `MediumItemRef` and `ItemRowSummary`, the `SidebarSelection` enum, scene-scoped navigation state above the layout switch, and intents routed per scene (`FocusedValue`) instead of global ticks. Risk H (root navigation), size L. Its verification: two main macOS windows act independently; folding and unfolding keeps the selection without a store round trip; the Phase 5 acceptance in `docs/1.x/cross-media-ux-plan.md`.

## How to start it

**Session 1 (Stage A).** Paste:

> Run the unified-flags plan (`docs/1.x/unified-flags-plan.md`) for the Apple clients and the server as one session, following Session 1 of `flags-and-cross-media.md` and `00-working-agreements.md`. The maintainer's answers to decisions 1 to 3: `<paste>`. Write a short scope doc against current stage first: open questions at the top, one line per PR saying what the maintainer will see change. Then A0, A1 (it can merge at once), A2, A3 and A4, one open Apple PR at a time. A3 merges only when A1 is in prod and gate G0 holds. Promote only after A4. Android is out (android-parity.md leg L1). Keep the tester identifiers. Stop and ask before changing any source scan. Verify on the Mini with stage test account 1 on macOS, iPad, iPhone and visionOS, plus one Duo simulator pass on the Studio.

Point it at this plan and `00-working-agreements.md` (both in `docs/1.x/post-wave-3/`), this plan's "Background from the rearchitecture" (Wave 1.5's decision 12 and the feeds audit's F8) and feed-bulk-actions.md (what it changed in the feed list).

**Sessions 2 to 5.** Each opens when its gate clears, with this brief:

> Run cross-media Phase `<N>` (`docs/1.x/cross-media-ux-plan.md`) on the Apple clients and the server, following Session `<M>` of `flags-and-cross-media.md`. The maintainer's answers to this phase's decisions: `<paste>`. Read the plan doc's Progress table and the errata first. Write a short scope doc with any open questions at the top, including the source scans this plan names. Server PRs first; client PRs merge only after the server change is in prod. One open Apple PR at a time; check the hotspot owners before each PR.

Point it at this plan, `00-working-agreements.md`, the sibling plans its gate names, and, for Sessions 4 and 5, the feeds audit's notes under "Background from the rearchitecture". Rigs: the Mini (simulator lanes, the two stage test accounts, old-build and downgrade checks), the Studio (Duo simulator), the maintainer's devices (Spotlight, the two-device check, the physical Duo), and AWS stage only through CI (Lambda via `app.yml`, Terraform via `infra.yml`).

## Risks and checks

- **Shipped builds.** Check each on the Mini with the 1.31.0 build against stage. After Stage A, an old Apple build lists an edited Flagged entry as a custom flag; its flag menu should show that row unchecked even when set, because `FlagPalette.slots(in:)` keeps only `cabal-flag` atoms (`FlagPalette.swift:94-96`), so picking it sets rather than clears *(inferred from the code; verify)*. After Phase 2, old builds ignore `flags`. After Phase 4 under 6a, old builds never see a feed rule; check by hand that a save from one leaves `feedRules` alone.
- **Old server, new client.** Rule 1 (prod first) prevents all three silent failures. A3's encode rule is the second guard for the palette: the system entry reaches the wire only after an edit.
- **Feed-store downgrade.** After sqlite PR 0.2, a downgrade sets schema 7 aside and B2.3's import brings flag marks back. A build from before PR 0.2 still deletes it; accepted for testers. The downgrade drill checks it.
- **Room.** Android must not bump Room without a real migration, or it loses unsent marks; android-parity.md owns it.
- **Phase 4 deploy order.** Lambda code deploys through `app.yml` and Terraform through `infra.yml`, independently. B4.1 rides a promotion before B4.2's code, and evaluation is best effort.
- **Feed-rule cost.** The synthetic check in Session 3, then a week of fetcher duration and reads after Promote.
- **Root navigation (B5.1).** Restore and fold regressions; it ships alone in its release, with the restore suites, visionOS and the Studio fold pass.
- **Two-device check (Phase 2).** It needs one stage account on two rigs, and a sign-in on one device can sign out another. Coordinate, or rely on the Kit merge test plus one device by hand.
- **Lint caps and the ratchet.** Extract types (row parts, the flaggable menu value), never `+Foo.swift` files. `MessageDetailView+FlagOptions.swift`, `FeedReaderToolbar.swift`, `MessageListView+Rows.swift` and `RulesView.swift` hold allowlisted `#if` blocks; add none.
- **CI pacing.** One open Apple PR from this plan at a time; server and Terraform PRs use no macOS jobs.

## Not in this plan

- Cross-media Phase 3 (feed bulk selection, Forward as Email) and its stale `bulkMode` text, and #1914: feed-bulk-actions.md. Phase 2 only adds Set flags to its bar.
- Every Android leg (unified flags Phase 4; cross-media 2b, 4b and 5 on Android; the first real Room migration): android-parity.md, by decision 3.
- #1956, #1957, the set-aside import, the shared queue and the cross-folder flagged query: sqlite-mail-store.md.
- #1901 and #1903: shared-load-error-state.md. Decision 6a lets its decision 3 close #1901.
- #2014 and #2024: ipad-layout-and-keyboard.md. #2016 and #2039: multi-window-and-restore.md. #2022, #2031, #2040: the Rules editor's owners.
- The Phase 1 Status fix: docs-and-bookkeeping.md PR 2. The two comments naming `SpotlightRouting.swift` (`AppDelegate.swift:113`, `AppRootLifecycle.swift:65`) need no fix: the file exists, and docs-and-bookkeeping.md checked both.
- A stored feed snippet so the list stops loading bodies (the feeds audit's F16, smaller items, offered by feed-bulk-actions.md as a schema 7 ride-along): declined. The column alone does nothing; the list query and the reader's body load would also change, in feed-bulk's files, and the audit rates the measured cost low. It waits for a later bump.
- Feed notification delivery: `rss-implementation-plan.md` Phase 8, not started.
- Keyword mute, server-side cross-feed search, the React and Linux clients: declined or non-goals.
- The star on address favourites (`unified-flags-plan.md:349-352`): a recorded follow-up.
- Feed pill counts covering only device-held items (#1946): the 1.4 design.
- A detached reader window: detached-reader-window.md, which can widen to B5.1's `ItemRef`.

## Sources

- Plans in the repo: `docs/1.x/unified-flags-plan.md` (all), `docs/1.x/cross-media-ux-plan.md` (all), `docs/1.x/rss-requirements.md:565-581`, `docs/1.x/rss-implementation-plan.md:23-34`, `CHANGELOG.md:1083-1190`.
- `00-working-agreements.md` (in this folder).
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Code at 50e6022: `apple/CabalmailKit/Sources/CabalmailKit/Settings/FlagPalette.swift:54-96`, `RSS/RssStore.swift:35, 78-87, 469-472`, `RSS/RssStore+State.swift:164-171`, `Models/MessageRef.swift:27`, `Models/Rule.swift:11-22`, `Models/MessageFilter.swift:8-11`, `Spotlight/SpotlightIndexer.swift:132, 159`; `apple/CabalmailKit/Tests/CabalmailKitTests/FeedStoreSignOutTests.swift:47-52`; `apple/CabalmailUI/Shell/SignedInRootView.swift:1-32`, `Shell/WideMail.swift`, `Shared/Primitives/SelectionModel.swift:15`, `Navigation/SceneNavigator.swift:695`, `Navigation/AppRoute.swift:16-20`, `Navigation/DeepLinkRouter.swift:6-14`, `Commands/WindowCommands.swift:10-14`, `Commands/MessageMenuCommands.swift:53-54`, `Mail/Reader/MessageDetailView+ChordHosts.swift:27-28`, `Mail/MessageList/MessageListView.swift:552`, `Mail/MessageList/MessageListView+Rows.swift:414-486`, `Mail/Folders/FolderListView+Helpers.swift:100`, `Mail/Store/MailMutationService.swift:117`, `Feeds/ItemList/FeedItemListView.swift:10, 200, 304-341`, `Feeds/Reader/FeedReaderToolbar.swift:25-31, 72-80`, `Feeds/Reader/FeedReaderToolbarLayout.swift:7`, `Feeds/Sidebar/FeedSidebarContent.swift:16-21`, `Settings/FlagPaletteSettingsView.swift:10-12`, `Settings/NotificationSettingsSection.swift:1-40`, `Rules/RulesViewModel.swift:111`; `apple/CabalmailTests/AllFeedsRowSourceScanTests.swift:21-23`, `FolderSwitchPlacementTests.swift:91`, `CompactBrandMarkSourceScanTests.swift:19-31`; `apple/.swiftlint.yml:47-50`; `apple/platform-conditionals-allowlist.txt`; `lambda/api/set_preferences/function.py:61-75, 103, 152, 180-235`, `set_flag/function.py:51-54`, `rss_set_item_state/function.py:34-82`, `_shared/rss_api.py:48, 275-313`, `search_envelopes/function.py:9-13, 151-188`, `set_rules/function.py:234-236, 317-323`, `rss_fetch/function.py:286-326`, `_shared/tests/test_set_preferences_app_map.py`; `docker/shared/compile-user-rules.py:615`; `terraform/infra/modules/table/main.tf:397-450`, `terraform/infra/modules/app/rss_fetcher.tf:194-262`; `.github/workflows/app.yml:670-690`, `lint.yml:279`; `android/kit/.../rss/RoomRssStore.kt:355-366`, `api/ApiClient.kt:105`; `linux/xtask/tests/support/mod.rs:26`. Git: 9370b69f and 610d4e22 (cross-media plan), ede7b269 (3.2 E), 0f9422b7 (#2019).
- GitHub (checked 2026-10-12): open #1901, #1903, #1914, #1956, #1957, #1962, #2014, #2016, #2022, #2024, #2031, #2039, #2040; closed #1706, #2019. No open issue asks for unified flags or cross-media Phases 2 to 6.
- Sibling plans in this folder, read for hand-offs: sqlite-mail-store.md (rule 6, the schema 7 window in its design rules, PRs 0.1, 0.2, 4.5, 5.1, gate G5, hotspot table), android-parity.md (decisions 3 and 6, PR 9, legs L1 to L4), feed-bulk-actions.md (hotspots, F16 offer), ipad-layout-and-keyboard.md (PRs A, C, F), multi-window-and-restore.md (W4, session 1), shared-load-error-state.md (A3, A6, B1, decision 3), mail-navigation-refactors.md (PR 1, PR 7), docs-and-bookkeeping.md (PR 2), platform-conditionals.md, duo-support.md, detached-reader-window.md.
