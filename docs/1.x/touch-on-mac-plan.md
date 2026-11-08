# Touch on Mac — macOS Client Plan

Written 2026-11-04 against `stage` at `f1596eef8` (release 1.42.2). Line numbers are as of that commit; re-check them before starting.

## Context

Apple announced the first touchscreen Mac on 2026-10-28: the MacBook Pro with PROLED XDR Display (14.2″ and 16.3″, M5 Pro and M5 Max, 10–120 Hz ProMotion, a Dynamic Island in place of the notch). It runs macOS 27 and goes on sale 2026-11-06. Touch is an extra input alongside the keyboard and trackpad, not a new mode: Apple's design guidance is that macOS on a touch Mac "doesn't look any different", and that apps should keep their layout and control sizes and make *tap targets* bigger, not the controls.

This plan audits the macOS Cabalmail client for touch and lists what to fix. The plan doc itself is all that can be written before the hardware arrives (expected around 2026-11-06), apart from one item that helps every Mac today (item 0).

### What macOS does for an app that changes nothing

- **Standard AppKit and SwiftUI controls are touch-native:** buttons, controls, tables, collections, split views, tabs and scrolling all work with no code change. Menus show slightly larger rows under a finger, and steppers, sliders and dials expand while touched.
- **Everything else gets mouse emulation** (TN3212 and Apple's AppKit article "Adopting gesture recognizers in your app"):
  - A tap becomes `mouseDown` then `mouseUp`.
  - A touch that pans immediately becomes **trackpad scroll events**.
  - A long press without movement becomes `rightMouseDown` (a context menu).
  - A touch held briefly and then moved becomes a **drag** (`mouseDown` / `mouseDragged` / `mouseUp`).
  - A two-finger pinch or rotation becomes trackpad magnify and rotate.
  - Emulation covers one or two fingers only.
- **What touch does not do:**
  - There is no hover. `NSTrackingArea` and `mouseMoved` are pointer-only, and Apple says tooltips "shouldn't be revealed on touch".
  - Direct touches never reach event monitors, `NSApp.sendEvent` or the responder chain. Gesture recognizers are the only way to receive them.
  - AppKit does not turn touch swipes into `trackSwipeEvent` swipes.
  - `NSApp.currentEvent` and `NSEvent.pressedMouseButtons` are not reliable for touch.
- **The tap target is 36 pt on each axis**, the physical equivalent of iOS's 44 pt. This figure comes from Apple's tech talk "Bring Touch to your Mac app"; the HIG gives no number.
- **Apple advises against branching on "is this a touch Mac".** `NSScreen.touchCapabilities.contains(.multiTouch)` exists, but on macOS 27 it reports true for every display whenever a Sidecar iPad is connected.

### New API (macOS 27)

- SwiftUI `GestureInputKinds`: `.directTouch`, `.indirectTouch`, `.pointer`, `.pencil`, `.all`. It is accepted by `onTapGesture(count:coordinateSpace:inputKinds:perform:)`, `onLongPressGesture(…inputKinds:…)` and the gesture initializers. It filters which input a gesture accepts; it does not detect touch.
- AppKit gesture recognizers:
  - `allowedTouchTypes = .direct` together with `buttonMask = 0` gives a touch-only recognizer.
  - `isCancellableByScrollGesture`.
  - `NSPanGestureRecognizer.minimumNumberOfTouches` and `maximumNumberOfTouches`.
  - Subclasses built with the 27 SDK must override `location(in:)`.
  - `NSView.exclusiveGestureBehavior`.
- `NSControl.Events` (`primaryActionTriggered` and others).
- `NSScrollView` gains touch-scrolling properties and pull-to-refresh through `NSRefreshController`.
- `NSIsTouchNative` (Info.plist) opts out of the extra emulation. Most AppKit apps don't need it, and neither do we.
- `directTouchSystemGesturesDisabled()` and its AppKit and Catalyst counterparts arrive with the Xcode 27.3 beta (released 2026-11-03). We have no use for them.

The deployment floor is macOS 15 (`apple/project.yml`), so any of this goes behind `#available(macOS 27, *)`, as the 27 swipe-container path already does.

### Testing without the device

Apple: "Use Sidecar to test touch input without a Mac that has a touch display … AppKit then routes touch on its screen the same way it does on a Mac with a touch display." This needs an iPad on iPadOS 27 connected to a Mac on macOS 27. Everything in the audit below except the final device pass can run that way. There is no simulator path, and the cloud containers can't run any of it.

### Sources

- Apple Newsroom, 2026-10-28: <https://www.apple.com/newsroom/2026/10/apple-unveils-groundbreaking-macbook-pro-with-proled-xdr-display/>
- Touch on Mac hub (videos, labs on Nov 18 and 19): <https://developer.apple.com/touch-on-mac/>
- TN3212, Adopting gesture recognizers for Sidecar touch support: <https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support>
- Adopting gesture recognizers in your app: <https://developer.apple.com/documentation/appkit/adopting-gesture-recognizers-in-your-app>
- `GestureInputKinds`: <https://developer.apple.com/documentation/swiftui/gestureinputkinds>
- HIG, Gestures: <https://developer.apple.com/design/human-interface-guidelines/gestures>
- Tech talks "Bring Touch to your Mac app" (111468) and "Design for Touch on Mac" (111456), as quoted in <https://blakecrosley.com/blog/touch-on-mac-for-developers>

Apple's documentation pages are JavaScript-rendered. Their text is readable at the `https://developer.apple.com/tutorials/data/<path>.json` form of each URL.

## What the audit found

A sweep of `apple/CabalmailUI/` and `apple/CabalmailMac/` at the commit above found:

- **No `mouseDown`/`mouseDragged` overrides, no `NSTrackingArea`, `onHover` or `onContinuousHover`, no `NSEvent` monitors, no `trackSwipeEvent`.** None of the code paths that touch breaks outright are present.
- **The Mac client is SwiftUI throughout.** The AppKit it touches is the three `WKWebView` representables plus small `NSViewRepresentable` hooks (`SplitViewAutosaveDisabler`, `ComposeWindowCloseInterceptor`, `HostingWindowReader`) that take no input.

So the work is verification plus a few targeted fixes, not an input-layer rewrite.

## Decisions

1. **Branch on input, not on device.** Follow Apple: no "is this a touch Mac" checks and no touch-only layouts. Where something needs a touch path, use `GestureInputKinds` or a recognizer whose `allowedTouchTypes` is `.direct`. *Recommended; the default if unanswered.*
2. **Tap targets grow invisibly.** Where a Mac control's hit area is under 36 pt, widen its hit area (`contentShape` over a larger frame, or padding inside the button's label with the visual unchanged) rather than drawing it larger. This matches the HIG's "Make tap targets bigger, not the controls themselves". *Recommended; the default if unanswered.*
3. **Sidecar first, device second.** Run items 1–8 over Sidecar as soon as there is time, and keep the device pass (item 9) for what Sidecar can't show: palm rejection, a finger near the trackpad, hinge wobble and real-world target sizes. *Recommended.*

## Progress

| # | Item | Status |
|---|---|---|
| 0 | Pinch-to-zoom in the Mac readers | Released in 1.43.0 (#2321); pinch and double-tap work on the device |
| 1 | Message-list swipe actions under touch | Done: mail (#2346) and address rows (#2350) swipe under a finger on the device (2026-11-07) |
| 2 | Long press on rows: context menu vs drag | Drag to folder works by trackpad (#2342); touch drag and touch menu out of scope, by decision |
| 3 | Tap targets under 36 pt | Done: our glyph buttons released in 1.43.0 (#2323, #2324); the mini switch takes a finger easily on the device |
| 4 | Meaning carried only by a tooltip | No change needed |
| 5 | Pull-to-refresh vs toolbar Reload | Works on the device (2026-11-07); no change needed |
| 6 | Composer web view under touch | Works on the device (2026-11-07), except fine-grained touch selection |
| 7 | Article view back/forward swipe on Mac | Released in 1.43.0 (#2325, #2326); trackpad only, a finger doesn't navigate, by decision |
| 8 | Things that should just work (spot checks) | All pass on the device (2026-11-07) |
| 9 | Device pass on the MacBook Pro | Done as far as wanted (2026-11-07); the hardware-only checks skipped, by decision |

## Item 0 — Pinch-to-zoom in the Mac readers

**Status:** Released in 1.43.0 (PR #2321). On the MacBook Pro (2026-11-07), a pinch on the display zooms both readers, and a double-tap zooms too.

`WKWebView.allowsMagnification` defaults to false on macOS, so a trackpad pinch did nothing in the mail reader or the feed article view, while iOS zooms both. PR #2321 turns it on in `makeReaderWebView` and in `ArticleWebCoordinator.makeWebView`. It helps every Mac with a trackpad today. On the touch Mac, a pinch is emulated as a trackpad magnify, so the same switch should cover it; item 9 confirms that.

`ReaderMagnificationTests` pins both settings, and pins that a message loaded into a zoomed reader opens at 1×. WebKit resets the zoom on a new load by itself. A probe during that PR showed `visualViewport.scale` following the Mac magnification, so the link bridge's popover anchor stays correct when zoomed.

**Left for the device pass:** a smart-zoom double-tap (two-finger double-tap on a trackpad) should also work with magnification on; confirm it. Also check that the plain-text body, a SwiftUI `Text` in a `ScrollView`, doesn't feel broken by comparison. It does not zoom, and making it zoom is not in scope.

## Item 1 — Message-list swipe actions under touch

**Status:** Done (2026-11-07). Mail rows (#2346) and address rows (#2350) swipe under a finger on the MacBook Pro's stage build. Rows in the address list swipe by two-finger trackpad but not by a finger, though one finger scrolls that list (2026-11-07, found during item 8). Feed rows, also plain `List` rows, swipe under a finger; address rows differ in being a `Button` (tap to copy) and `.draggable`. A local build with a switch between four variants settled it on the device: rows swiped by finger with the `Button` replaced by a tap gesture, with the drag source kept or not, and not with the `Button`. #2350 copies on a tap through `rowTapAction` (`Shared/Chrome/RowTapAction.swift`), which keeps the row one accessibility button whose activate copies; `RowTapActionTests` drives a click and an `AXPress` through such a row in a `List`. On the stage build, address rows swipe under a finger (2026-11-07). A finger's swipe on a message row revealed nothing at first (2026-11-06); after three fixes that each failed in a different way on the device (#2339, #2341, #2345, below), #2346 left one finger scrolling the mail list and swiping a row at once, both edges, with the trackpad, drag-and-drop and the secondary-click menu unchanged.

**What the device showed.** On the MacBook Pro, a finger's swipe on a message row revealed nothing, leading or trailing, while feed rows (plain `List` rows) swiped under a finger and a two-finger trackpad swipe on a message row worked as on any Mac. So the macOS container's reveal answers the trackpad's scroll events and nothing else, the second of the two outcomes below.

**The fix.** It reuses the iPad's drawn half (`TrackpadSwipe.swift`), which already covered the opposite gap: there the container answers touches but not a trackpad. The tracker, coordinator and drawn reveal were iOS-only; they now compile on macOS too. Each platform's input sits behind one type in `Platform/TrackpadSwipeRecognizer.swift`:
- iPadOS keeps its scroll-only pan.
- macOS first got an `NSPanGestureRecognizer` with `allowedTouchTypes = .direct` and `buttonMask = 0`, bridged through `NSGestureRecognizerRepresentable` (#2339). On the device a finger still revealed nothing, and vertical scrolling was unaffected. A likely cause: its delegate's `beginsSwipe` check, asked at touch-down with no movement yet, refused every touch. It is now a SwiftUI `DragGesture(minimumDistance: 10, inputKinds: .directTouch)` (macOS 27), with no delegate. It reports a swipe once the movement reads as one, and the tracker ignores a repeated `began` and an `ended` that none opened. Each finger drag that ends writes one `RowSwipe` line to Settings → Debug Log, so if this fails too, the log shows whether a finger reaches the row at all. On the device the drag swiped, but attached with `.gesture` it claimed every finger that moved on a row, vertical ones included: the mail list stopped scrolling under a finger, and a swipe took only after a hold. On macOS it is now attached with `.simultaneousGesture` (`rowSwipeInput`, in `Platform/`), beside the list's scrolling, so a vertical drag scrolls and a horizontal one reveals; iPadOS keeps `.gesture` for its trackpad input. `SwipeActionContainerSourceScanTests` pins the attachment, since a finger can't be made in-process. The device's `RowSwipe` log backed the cause and showed one more problem. Nearly every finger drag on a row ended vertical, "not a swipe": scroll attempts the drag had swallowed. And no horizontal swipe logged an end at all: SwiftUI cancelled those drags, and a SwiftUI gesture reports no cancel. That left the row tracking, deaf to its next swipe (`began` is ignored while tracking) and to retraction. The Mac's drag now carries a `@GestureState` flag, which SwiftUI resets on a cancel as on an end, and a reset reaches the tracker as a cancel one turn later (`TrackpadSwipeTracker.cancel`). A clean end has settled the swipe by then, so the cancel is ignored; one that interrupted a swipe retracts the row and logs a `RowSwipe` line.

**#2345 on the device (2026-11-07):** a finger swipes at once, both edges, and the trackpad, drag-and-drop and the secondary-click menu all work, but one finger still doesn't scroll the mail list. Its `RowSwipe` lines show the drag seeing each vertical drag and leaving it alone ("not a swipe"), and the list not scrolling all the same: a SwiftUI drag that takes direct touch on a row keeps the finger from the list's scrolling, attached ahead of it or beside it. In #2339's build, one finger scrolled the list with an AppKit recognizer on every row. So the macOS input is that recognizer again, without what kept it from firing: no `gestureRecognizerShouldBegin` veto (asked at touch-down, before any movement, it refused every touch). It recognizes alongside every gesture, the scroll view's touch scrolling included, and reads each touch's axis off its movement (`TrackpadSwipePolicy.touchAxis`: undecided until 8 pt, then sideways is a swipe and anything else is left to the list). Its coordinator keeps the touch's axis across calls and reports a cancel mid-swipe, so the tracker's cancel handling still applies. `TouchRowSwipeTests` pins the configuration, that it runs alongside other gestures, that no delegate method vetoes a touch, and the axis rule. Each touch logged `RowSwipe` lines while this was checked on the device. Before promotion they were removed, being written on every touch, leaving only a debug-level line when a swipe in progress is cancelled (`TrackpadSwipeTracker.cancel`), the sign of the stuck row coming back.
- visionOS gets an inert stand-in, since it draws no reveal.

`HostPlatform.drawsRowSwipeReveal` (iOS and macOS) replaces the six `#if os(iOS)` blocks that gated the reveal, so `SwipeActionRow.swift` and `TrackpadSwipe.swift` leave the platform-conditionals allowlist. Tests:
- `TouchRowSwipeTests` pins the drag's input kind, the capability, the tracker on macOS, and the tracker's tolerance of a stateless drag (both tolerance tests fail with the tracker's two new guards removed).
- `SwipeActionContainerSourceScanTests` now pins the capability gate in place of the iOS-only one.
- The in-process trackpad-swipe suites still pass with the recognizer on every row.

**Left for the device:** nothing. Both mail and address rows were checked under a finger on the stage build (2026-11-07).

This is the highest-risk item. On macOS 27 the message list's swipe-to-dispose and toggle-read come from SwiftUI's `.swipeActions` outside a `List`, coordinated by `.swipeActionsContainer()` (`apple/CabalmailUI/Mail/MessageList/SwipeActionRow.swift`). On macOS that container reads the trackpad's two-finger horizontal scroll natively (`TrackpadSwipe.swift:16-17`). Below 27, each row borrows a single-row `List` for the same thing. The same `.swipeActions` question applies to the folder list (`FolderListView.swift:366`), the address list (`AddressListView.swift:317,327`) and the feed item list (`FeedItemListView.swift:296,299`), which use plain `List` rows.

No source documents how SwiftUI `.swipeActions` behaves under touch on macOS. Two outcomes are plausible:

- **It works already.** SwiftUI is touch-native and treats a horizontal finger drag as a swipe, or the emulation turns the pan into trackpad scroll events, which the container already reads.
- **It doesn't.** The pan is taken as vertical scrolling, or as a drag lift (see item 2), and no row reveals.

**Steps:**
1. Over Sidecar, swipe a message row leading and trailing, partially (the reveal, then a tap on the capsule) and fully (the action runs), on the 27 path.
2. Do the same on the folder, address and feed-item lists.
3. Check that only one row is revealed at a time (#901's property), and that a vertical finger scroll over a revealed row retracts it.

**If it fails:** add a touch half the way `TrackpadSwipe.swift` adds a trackpad half on iPadOS, but the other way round. That is a recognizer that sees direct touches only (`allowedTouchTypes = .direct`, `buttonMask = 0`, `isCancellableByScrollGesture = true`), behind `#available(macOS 27, *)`, driving the existing `TrackpadSwipePolicy` / `TrackpadSwipeTracker` rules and reveal. SwiftUI has no API to open its own reveal from code, which is why the iPad half draws its own. A `DragGesture(…, inputKinds: .directTouch)` may be enough in place of an AppKit recognizer; try it first. `SwipeActionContainerSourceScanTests` pins the container's shape: keep it green and don't edit its expected text.

## Item 2 — Long press on rows: context menu vs drag

**Status:** Drag to a folder works on the device, one message and several, by trackpad (#2342, 2026-11-07). Touch drag and touch hold-for-menu are out of scope, by decision (below). #2338's `DragMove` logging, which found the cause, was trimmed before promotion to one debug-level line per drop that says whether the fallback moved it.

**Touch drag and touch hold-for-menu: out of scope, by decision (2026-11-07).** On the device a finger neither lifts a message for a drag nor opens a row's context menu by a hold, in mail or (for the menu) in feeds. The decision: under a finger, mail should behave as feeds do, swipe and scroll only. Drag and the context menu stay with the trackpad and mouse (secondary click), where both work. Nothing is to be built for them under touch.

**Found on the device, not touch-specific.** Dragging one message onto a sidebar folder was accepted (the folder highlighted, the drop didn't bounce back) but nothing moved, with a finger or a trackpad; every other move route worked. #2338's `DragMove` lines showed the drop handler getting no payload at all ("Dropped 0 message(s) … from 0 payload(s)"), so no move was ever requested. A drag of several messages moved. The difference: since 21dec3832 (2026-10-29, released in 1.41.0) a single-message drag offers its `.eml` ahead of the move reference, so it can land as a file on the compose body or in Finder, and a folder's drop on macOS then decodes nothing from it. A several-message drag offers only the move reference. The exact pasteboard mechanism (the leading guess is the `.eml`'s suggested file name making it a file promise) wasn't pinned down: a real drag can't be driven in-process.

**The fix keeps the `.eml` first.** The list records the drag it lifts (`AppState.noteLiftedDrag`), and a folder drop that decodes no payload moves that drag instead, once, while it is fresh (two minutes; `AppState.moveDropped`). Folder drops no longer depend on the pasteboard, and the compose body and Finder still get the file. `AppStateMoveDropTests` covers it, and fails with the fallback off. Reverting the order instead would have fixed folders by breaking the compose body's single-message attach.

Message rows carry both `.draggable` (`MessageListView+Rows.swift:169`, the drag onto a folder) and a context menu (`rowContextMenu`, and the list-level `contextMenu(forSelectionType:)` on wide layouts). Under touch, "touch and hold" opens a context menu and "touch and hold, then drag" lifts an item. The two have to share the gesture.

**Steps:**
1. Long-press a message row: the menu opens, and it acts on the row pressed. On a wide layout with a multi-selection, check what it acts on.
2. Long-press, then drag a message onto a folder in the sidebar: the drop moves it.
3. Repeat on the folder rows (`FolderListView.swift:369`), the address rows, which are `.draggable` as well as menu-bearing (`AddressListView.swift:309`), the feed sidebar (`FeedSidebarContent.swift`) and the feed items (`FeedItemListView.swift:302`).
4. Long-press a sender in the reader header (`MessageDetailView+Header.swift:78`): the address menu opens.
5. Long-press a link in the HTML reader: the system WebKit menu opens (link preview stays off, #789), and a plain tap still opens our link menu (`HTMLBodyView+LinkBridge.swift`).

Fix only what fails. A likely fix, if the menu fires before a drag can start, is a `.draggable` that begins on touch movement. Check against Apple's guidance before writing one.

## Item 3 — Tap targets under 36 pt

**Status:** Done. The composer toolbar (PR #2323) and the toast, unsubscribed-banner and Contacts-picker buttons (PR #2324) released in 1.43.0. On the MacBook Pro (2026-11-07, 1.44.0), the Rules mini switch registers a finger's tap easily, so it stays as it is. No rule showed a "Retry" button to try; it is a standard `.bordered` button like the switch, and is left alone unless a finger is seen to miss it.

**The composer toolbar, done first.** Measured through the accessibility API, its buttons took taps on their glyph alone, not the 24 × 24 pt face their frame draws: Bold was 8 × 10 pt and Heading 1 was 16 × 15, because the label had no `contentShape`. The bar is shared, so this was as small on iPhone and iPad as on a Mac. The fix gives each button the gap around its face as hit area (`RichTextToolbar.hitPadding`): the stack's 4 pt spacing and the bar's 4 pt vertical padding. Each target is now 28 × 32 pt, with the faces, their spacing and the bar's height unchanged. That is short of 36 pt (and of iOS's 44), which only spreading the bar out could reach; that would be a visible change, and it waits for a look on the device. `RichTextToolbarHitTargetTests` pins the target size (it fails on the old toolbar), that neighbours don't overlap, and that the spacing and height are unchanged.

**The other candidates, measured in-process (2026-11-04).** Standard SwiftUI controls get a proper tap target from the system, so the question was the views whose hit area is drawn by us. Measured through the accessibility API in a test window (`HitTargetOracle`), in points:

| Candidate | Before | After (at least) |
|---|---|---|
| Toast close (`Shared/Banners/ToastBanner.swift`) | 10 × 10 | 30 × 26 |
| Toast action ("Copy", "Resume") | 46 × 13 | 60 × 29 |
| Unsubscribed-folder refresh (`MessageListView+UnsubscribedBanner.swift`) | 12 × 14 | 32 × 30 |
| Recipient Contacts picker (`RecipientFieldWithSuggestions.swift`) | 21 × 18 | 27 × 26 |
| Rules mini switch (`miniSwitchStyleOnMac()`) | 36 × 16 | unchanged: a system control |
| Rules "Retry" (`.bordered`, `.small`) | 48 × 20 | unchanged: a system control |

The first four took taps on their glyph alone. Unlike the toolbar, they sit in rows with no spare spacing to hand over, so they use `HitPaddedButton` (`Shared/Chrome/HitPaddedButton.swift`): the label is padded inside the button, which grows the button's frame and hit area, and the button hands the padding back to its parent as negative padding, so every row keeps its size. Real clicks showed this is the way it has to be done on macOS: a `contentShape` larger than the view (`Rectangle().inset(by: -8)`) takes no clicks beyond the button's frame. Each site's padding stays inside the padding its row already has and short of any neighbouring control. `HitPaddedButtonTests` drives real clicks into the padding (with a plain button as the control), pins each target's size (each fails on the old code), and pins each row's height.

**Left for Sidecar:** whether macOS's own touch handling gives the mini switch and the small bordered button a larger target than their accessibility frame shows, as Apple says it does for standard controls. Leave them alone if it does (#2040 settled the switch's shape).

## Item 4 — Meaning carried only by a tooltip

**Status:** No change needed (2026-11-04).

A touch has no hover, so `.help` text never shows under a finger. Every `.help` in the shared layer pairs with an `accessibilityLabel`, so VoiceOver is covered; the question was a sighted touch user. Of the seven uses:

- **The feed health badge** (`Feeds/Sidebar/FeedSidebarSection.swift:63`) is a bare warning or stopped icon whose sidebar tooltip is its only label. But selecting the feed, which is what a tap on the row does, shows the full explanation at the top of its item list, with the fetcher's own error text, which the tooltip lacks (`FeedItemListView+FilterBar.swift:80`, `FeedHealth.headline(for:)`). This works on every platform. A button on the badge would repeat that, and a button inside a selectable sidebar row would compete with the row's own tap.
- **The sort control** (`MessageListView+Sort.swift:28`) explains in its tooltip only why a search disables it ("Search results are listed newest first"). The results are visibly newest first, and a permanent footnote would shift the results layout to explain a button nobody can use there. Left as is.
- **The others are fine:** the "Import from Rich Text" button (`ComposerBody.swift:133`), the recipient picker and the rich-text toolbar carry a visible label or a standard glyph, and the tooltip only repeats it.

The reader's link status pill (`HTMLBodyView.swift`, `hoveredHref`) is hover-only by nature. A tap already opens the link menu, which shows the URL, so nothing is lost.

## Item 5 — Pull-to-refresh vs toolbar Reload

**Status:** Works on the device; no change needed (2026-11-07, 1.44.0 on the MacBook Pro). On macOS 27, `.refreshable` drives the system's pull-to-refresh, by a two-finger trackpad overscroll and by a finger:
- In mail and feeds, a pull refreshes the list. The pull's spinner above the list and the toolbar's `RefreshActivityIcon` both show while it runs. That is intended: the toolbar spinner reports that a refresh is running, whatever started it, and the pull's spinner is the system's answer to the pull.
- A second pull while a refresh runs starts no second one, by trackpad or finger, judging by the UI.
- The folder list and the address list behave the same. The feed sidebar can't be pulled on its own on macOS, where it shares the sidebar list with the mail folders; that list's pull is the folder list's.

macOS 27 adds pull-to-refresh to `NSScrollView` (`NSRefreshController`), and Apple's Mail, Safari and Calendar use it. We attach `.refreshable` to the message list (`MessageListView.swift:292`), the folder list, the feed sidebar and feed items, the address list, Settings and Users. On macOS before 27 that modifier did nothing visible, and the toolbar Reload button is the Mac's refresh.

**Steps:** pull down on each list. Pull-to-refresh is an `NSScrollView` feature, not a touch one, so a trackpad overscroll on any Mac running macOS 27 may already show whether `.refreshable` drives it; Sidecar or the device shows the touch side.
- **If `.refreshable` now drives the system's pull-to-refresh:** check it runs the same refresh as Reload, the spinner and `RefreshActivityIcon` don't both show, and a pull during a running refresh doesn't start a second one (`MessageListViewModel+Refresh.swift:37-39` explains why the pull's task is kept apart from the request).
- **If it does nothing:** decide whether pull-to-refresh is wanted on the Mac at all. The toolbar Reload already exists, so the default is to do nothing.

## Item 6 — Composer web view under touch

**Status:** Works on the device, except fine-grained selection (2026-11-07, 1.44.0 on the MacBook Pro):
- **Selection, partly.** A double-tap selects a word and a triple-tap a paragraph, but a finger can't set a selection's start and end precisely: there are no handles to drag. Once text is selected, touch and hold opens the editing menu. Our page registers no mouse, pointer or touch listeners, so selection is WebKit's own; whether a `contenteditable` page in Safari on the same Mac offers handles would show whether this is ours to fix at all. Until then, nothing is planned.
- **The toolbar.** Tapping Bold with text selected bolds it, and the selection stays.
- **Drops.** Dragging an image within the body places it inline, and a file dropped onto the body becomes an attachment, by trackpad and by finger.

The composer is a `WKWebView` running our own editor page (`RichTextEditorController`, `editor-bridge.js`) with JavaScript on. `editor-bridge.js` registers paste and drag/drop listeners (`dragstart`, `dragend`, `dragover`, `drop`) but no mouse, pointer or touch listeners, so caret placement and selection come from WebKit's default handling. Whether a touch on macOS WebKit fires touch events, pointer events or emulated mouse events to page script is not documented anywhere I could find.

**Steps:** over Sidecar:
- tap to place the caret;
- drag-select text, then long-press for the editing menu;
- tap the toolbar's buttons (item 3) with a selection active, and check that the selection survives the tap;
- drag an image within the body;
- drop a file onto the body: it should still go to the app, not into the page.

The sanitizer and drop-handling invariants listed in `CLAUDE.md` ("Page JavaScript in the three web views") must hold. `RichTextEditorControllerTests` and `RichTextEditorFileDropTests` cover them in tests; this item checks them by hand under touch.

## Item 7 — Article view back/forward swipe on Mac

**Status:** Released in 1.43.0 (PR #2325), with the iOS fix it needed (PR #2326). On the MacBook Pro (2026-11-07), a two-finger trackpad swipe goes back; a one-finger swipe on the display doesn't. That is accepted, by decision: nothing is planned for it. One iOS behaviour is still unexplained, below.

`ArticleWebCoordinator.makeWebView` set `allowsBackForwardNavigationGestures` on iOS and visionOS only, so on a Mac a two-finger trackpad swipe didn't go back on the publisher's page. The worry was the back/forward list: the reader rendering is a separate `loadHTMLString` in the same web view, so a swipe might land on a page the coordinator's state didn't expect.

- **The reader toggle adds no history.** A probe served the article from a custom URL scheme, since WebKit refuses a handler for `https` and tests here open no sockets, so the web view kept a real back/forward list. Both the reader rendering (`loadHTMLString` with the page as its base URL) and the toggle's return to the live page load the page's own URL, and WebKit replaces the current entry rather than adding one. After reader, toggle off and toggle on, the back list was still empty. A swipe only walks pages the user reached through links.
- **A swipe back after a link out of the reader was broken on iOS.** This is #2060's path, in the in-app article page (the toolbar's **Open article**). It is not the feed item's own content, which renders in `HTMLBodyView`, whose links open the link menu and never navigate; a first check made there didn't count. A check on an iPhone 16 Pro Max (2026-11-04), reproduced on macOS against a live macrumors.com article, found two problems:
  - Going back restored the reader rendering from WebKit's back-forward cache under a toggle reading "original", and the next toggle changed nothing.
  - The coordinator could also keep the linked page's URL, so a later toggle loaded the linked page in place of the article.

  The coordinator had never handled back or forward. #2326 fixed it on every platform: a main-frame `.backForward` navigation is read at its commit for its URL, whether it is the reader rendering (a marker the reader document carries) and whether it is complete, and the toggle is told what is on screen. `ArticleHistoryRestoreTests` drives a real link tap in the reader and fails with the fix off.
- **Still unexplained:** on the iPhone, a link out of the reader opened the linked page and then switched it to reader view, where #2060 keeps it as served. A scripted tap on macOS keeps it as served. Look at it on the device.

With #2326 in, the Mac takes the swipe too. `ArticleWebViewGestureTests` pins the setting (it fails on the old code).

**Left for the device pass:** whether a one-finger touch swipe on the touch display navigates too. AppKit doesn't turn touch swipes into navigation for apps that track swipes themselves, and it is not documented whether WebKit's own gesture takes direct touch. It should honour the system's "Swipe between pages" setting (`NSEvent.isTouchSwipeNavigationEnabled` for touch); confirm both on the device.

## Item 8 — Things that should just work (spot checks)

**Status:** All pass on the MacBook Pro (2026-11-07, 1.44.0): column resizing, the toolbar's split buttons and menus, the menu-bar extra, Settings, the address inspector and new-address sheet, swiping a toast away, a fast flick through a long folder, and arrow-key navigation after a tap. Address rows not swiping under a finger turned up along the way; it is recorded under item 1.

Over Sidecar, each of these should pass with no change:
- **Column resizing:** native `NSSplitView` on macOS (`Shell/Columns/ColumnResizeHandle.swift:64-67`).
- **The toolbar's split buttons** and their menus (`ReaderToolbarControlShape.swift`).
- **The menu-bar extra:** `MenuBarExtra`, `CabalmailMac/MenuBarExtraMenu.swift`.
- **Settings:** the Settings window's tabs and forms.
- **Address management:** the address inspector and new-address sheet.
- **Toasts:** dismissing a toast by dragging (`ToastBanner.swift:93`, a `DragGesture` that touch emulation turns into a drag).
- **Scrolling:** one-finger scrolling in every list and both reader bodies, including the index-addressed message list's paging (`WindowPager`, page cap 250) during a fast flick.
- **Keyboard:** list navigation (`MessageListView+Selection.swift:132-150`) still works after a touch has moved the selection.

File anything that fails as its own issue and add a row to the progress table here.

## Item 9 — Device pass on the MacBook Pro

**Status:** Done as far as wanted (2026-11-07, 1.44.0). Item 0's pinch and double-tap work; item 3's targets work and are comfortable under a finger, so the composer toolbar is not spread out; item 7's one-finger swipe doesn't navigate, which is accepted. The checks below that only the hardware can make (palm, edges, wobble, reading distance, the Dynamic Island) were skipped, by decision.

Re-run items 0–8 on the hardware, including what the shipped items left for the device:
- **Item 0:** a two-finger pinch on the display zooms the mail reader and the article view (AppKit emulates it as a trackpad magnify); a smart-zoom double-tap works too.
- **Item 3:** the composer toolbar's 28 × 32 pt targets, and the toast, banner and picker buttons, under a real finger. The toolbar stops short of 36 pt because reaching it would spread the bar out; decide here whether it should.
- **Item 7:** whether a one-finger swipe on the display goes back in the article view, and that the toggle matches the page after it (#2326).

Then add what Sidecar can't show:
- a palm resting on the trackpad while tapping;
- tapping near the keyboard and near the screen edges, where the system's edge swipes (Dock, menu bar, Notification Center) win;
- the screen wobbling under a tap;
- reading comfort at arm's length;
- whether the Dynamic Island crowds the toolbar.

Record what you find here, in each item's **Status:** line.

**Out of scope until something changes:** Live Activities in the Dynamic Island. Apple's talk says Golden Gate apps can create them, but the macOS 27.0 and 27.2 SDKs mark ActivityKit's macOS API unavailable. Mail has no natural Live Activity either; a long send queue or a sync progress would be the only candidates.

## Session brief

> Read `docs/1.x/touch-on-mac-plan.md` and `docs/1.x/post-wave-3/00-working-agreements.md`. Every item is done or checked on the MacBook Pro (see each **Status:** line); nothing is left, and the plan is complete. Should a touch problem turn up later, fix it the same way: its own PR to `stage`, one Apple PR in CI at a time, an `Apple:` changelog fragment, and a behavioural test where the behaviour can be driven in-process. A finger can't be made in-process, so when the cause is unclear, settle it with a local signed build that switches between variants on the device before writing the fix (item 1's address rows). The test tools this plan's work added: `HitTargetOracle` (a button's hit area from its accessibility frame, real in-process clicks, and `press(_:in:)` for an `AXPress`), `HitPaddedButton` (a glyph button's hit area grown without moving its row), `rowTapAction` (a whole-row tap that leaves a finger's swipe to the row's swipe actions), and `ArticleHistoryRestoreTests`' URL scheme handler (a web view with real history and no network). Add no `#if os(...)` outside `Shell/` and `Platform/`; branch on input (`GestureInputKinds`, `allowedTouchTypes`), never on "is a touch Mac". On the iPhone, item 7's open question (a link out of the reader switching the linked page to reader view) still wants a look.
