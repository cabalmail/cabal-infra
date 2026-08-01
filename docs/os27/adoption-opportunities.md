# OS 27 Adoption Opportunities

Features from Apple's 27.x releases (WWDC 2026; iOS 27, iPadOS 27,
macOS 27 "Golden Gate", watchOS 27, visionOS 27) that could enhance
Cabalmail's Apple clients. Compiled July 2026, while the releases are
in developer beta; public release expected September 2026.

## Adoption Timing legend

- **Free** — we automatically benefit when a device upgrades (or when
  we rebuild with the Xcode 27 toolchain). No code changes.
- **No Wait** — we can code for the feature today against current
  SDKs; devices begin benefiting as they upgrade.
- **Wait** — the feature needs 27-only APIs and the Xcode 27 SDK.
  Coding it now would break compatibility with today's devices and
  CI/App Store builds. (Once Xcode 27 GM ships, these can be adopted
  behind `if #available(iOS 27, *)` gates without dropping support
  for 26.x devices.)

## Features

| Feature | Brief Description | Benefits | Adoption Timing | My Notes |
|---|---|---|---|---|
| Swipe actions in any container | `.swipeActionsContainer()` brings swipe actions to any view in a scroll container, no longer `List`-only. | **Measured on an iPadOS 27 simulator 2026-08-01: this fixes the iPad leading-swipe won't-fix.** With the folder sidebar persistently *tiled* — the configuration a full June matrix proved impossible — both leading and trailing reveal at the shortest 120pt drag, with no gesture surgery, and vertical scrolling survives. Lets the message list drop its embedded per-row `List`, which in turn would let the iPad go back to a real tiled sidebar (retiring the collapsed-column + floating-panel workaround) and likely retire the background-watchdog placeholder gate. Prototype on `claude/os27-swipe-proto`; details in `~/swipe-repro/FINDINGS-os27.md`. | Wait | |
| Reorderable containers | `.reorderable()` / `.reorderContainer` bring drag-to-reorder beyond `List` to any container (incl. `LazyVGrid`), and to watchOS for the first time. | Drag-to-reorder folder and address lists with one API across iOS, macOS, and the Watch app. | Wait | |
| New toolbar APIs | Visibility priority, overflow menus, pinned trailing items, minimize-on-scroll — precise control over how toolbar items collapse on compact screens. | We dictate what hides and what never moves in reader/compose toolbars, instead of letting the system reshuffle. Aligns with the stable-control-footprint rule. | Wait | |
| AsyncImage HTTP caching | `AsyncImage` now respects server HTTP cache headers automatically, for every app. | Free client-side caching for BIMI logos once the BIMI display work lands. Server prep is No Wait: make sure `fetch_bimi` responses / presigned URLs send sensible cache headers today. | Free (client); No Wait (server cache headers) | |
| SwiftUI performance | `@Observable` objects in `@State` initialize lazily once per view lifetime; unified `ContentBuilder` cuts compiler type-checking paths. | Cheaper view re-init on large mailbox views; faster builds on the CI Mac. Arrives with an Xcode 27 rebuild, no code changes. | Free | |
| Liquid Glass refresh | Apps automatically adopt the updated system appearance when running on 27.x. | Current look stays current for free — but it's silent visual churn; the tester27/fixer27 pipeline should watch for regressions in beta. | Free (watch for churn) | |
| App Intents 2.0 (SiriKit deprecated) | App Intents is now the only Siri framework; adds streaming responses, multi-turn follow-ups, richer entities, View Annotations. SiriKit gets a 2–3 year deprecation clock (we don't use it, so no forced migration). | The address feature is a perfect intent surface: "make me a new address for this vendor" / "revoke the address I gave X" via Siri, Shortcuts, and Spotlight. Base App Intents works back to iOS 16; the 2.0 conversational extras light up on 27. | No Wait | |
| Rebuilt system search | Apple rebuilt the index behind Spotlight/Photos/Mail: more stable, near-immediate indexing of new content. | Indexing Cabalmail messages via Core Spotlight (available today) puts our mail in system-wide search; the rebuilt index makes it faster and more reliable on 27 for free. | No Wait (Core Spotlight); Free (index improvements) | |
| On-device mail RAG | `SpotlightSearchTool` pairs with `LanguageModelSession` for fully local retrieval-augmented search over Core Spotlight data. | Semantic "find that email about…" search over the mailbox with nothing leaving the device — a natural fit for a privacy-first self-hosted system. Depends on the Core Spotlight indexing above. | Wait | |
| Foundation Models updates | New `LanguageModel` protocol makes on-device, Gemini, and Claude models interchangeable; image input; free Private Cloud Compute for smaller developers. | Thread summarization, smart reply drafts, spam/address triage — all client-side, no server-side AI surface added to the mail plane. | Wait | |
| visionOS 27 | Curved windows, eye-aware notifications, Siri visual intelligence, panorama environments; a bigger update than the keynote suggested. | Mostly free polish for the native visionOS client. Verify how eye-aware notifications interact with our APNs pushes during beta. | Free (mostly) | |
| Adaptive layout / hinge APIs | SwiftUI/UIKit APIs for hinge-state detection and multi-configuration displays (foldable hardware). | The iOS app's split-view layouts would adapt cleanly to a foldable iPhone. No hardware exists yet; nothing to do until it does. | Wait | |

## Sources

- [MacRumors — Everything Apple announced at WWDC 2026](https://www.macrumors.com/2026/06/08/wwdc-2026-recap/)
- [Apple — WWDC26 SwiftUI guide](https://developer.apple.com/wwdc26/guides/swiftui/)
- [WWDC26 What's New in SwiftUI — developer breakdown](https://dev.to/arshtechpro/wwdc26-whats-new-in-swiftui-a-developers-breakdown-1333)
- [TechTimes — App Intents replaces SiriKit](https://www.techtimes.com/articles/318005/20260608/wwdc-2026-app-intents-replaces-sirikit-gemini-siri-migration-clock-starts.htm)
- [MacRumors — 2026 Platforms State of the Union (Foundation Models)](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- [Let's Data Science — Apple rebuilds search infrastructure](https://letsdatascience.com/news/apple-rebuilds-search-infrastructure-powering-spotlight-and-b37590b7)
- [MacRumors — visionOS 27](https://www.macrumors.com/2026/06/09/visionos-27-siri-ai-eye-aware-notifications/)
- [UploadVR — visionOS 27 is a much bigger update](https://www.uploadvr.com/visionos-27-announced-apple-vision-pro-wwdc-26/)
