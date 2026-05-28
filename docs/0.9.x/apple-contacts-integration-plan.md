# Apple Contacts integration for the iOS/macOS clients

Status: planned. Forward-looking; supersede with the as-shipped notes once each phase lands.

## Goals

1. Where the user already has a name for an email correspondent in Apple Contacts, surface that name everywhere addresses appear — message list, message detail, compose autocomplete.
2. Where the user has a profile photo for a sender in Apple Contacts, use it as the avatar in message detail, ahead of BIMI.
3. Compose autocomplete: typing into To/Cc/Bcc suggests matches from Contacts by name or by email; selecting a suggestion fills the field with `Name <addr@host>`.
4. A picker affordance on the compose window that lets the user select recipients from a list of Contacts.
5. Register Cabalmail as a handler for `mailto:` links on both iOS and macOS so the user can pick it as their default mail app (on macOS this still requires the user to set it in System Settings; we can only register capability).

## Non-goals

- **No Gravatar.** Querying gravatar.com keyed on a sender's email hash opts the recipient into a third-party lookup on the sender's say-so. The avatar precedence is contact photo -> BIMI -> initials, full stop.
- **No syncing contacts to the server.** Cabalmail is a self-hosted system; contact data must stay on the device. The only contact-derived data that crosses the wire is whatever the user themselves types or selects into To/Cc/Bcc when they send.
- **No write-back to Contacts.** Adding a sender to the address book is the OS's job (long-press a chip in Mail does this); we surface read-only enrichment, not authorship.
- **No address-book-driven address creation.** "New address per contact" is the Cabalmail compose idiom and is unchanged.
- **No CardDAV or other contact-sync protocol.** The system contacts framework is the contract.

## Privacy contract

- All contact reads happen via `Contacts.framework` on-device. No network round-trip is added.
- The compose path already serializes addresses to the network on send; nothing new there.
- Logging audit: before merging compose autocomplete, confirm that no info-level log line captures full recipient strings. Any such log becomes a contact-PII line the moment autocomplete is wired in.
- The `NSContactsUsageDescription` string explains that contacts are read locally to suggest names and avatars and never leave the device. Same copy on iOS and macOS.

## Data model

Contacts data is a side channel, not a first-class model. `EmailAddress` already carries an optional `displayName`; the hydration helper introduced in Phase 1 returns a name string (or photo data) given an address and the call site decides what to do with it. No new fields on `EmailAddress` or `Envelope`. No persisted cache — the in-memory cache lives for the app session and is rebuilt on launch. (`CNContactStore` reads are fast enough that disk persistence would buy nothing and would put PII on disk we don't need to put there.)

## Phases

Each phase is independently shippable. Phases land in order; later phases assume earlier phases.

### Phase 1: foundation (CabalmailKit + permissions)

- New `CabalmailKit/Sources/CabalmailKit/Contacts/ContactsStore.swift` with a `ContactsStore` protocol exposing `displayName(for: EmailAddress) async -> String?` and `photoData(for: EmailAddress) async -> Data?`. A `LiveContactsStore` actor backs it with `CNContactStore`, an in-memory cache keyed by lowercased email, and a `nil`-returning fast path when authorization is `.denied` / `.restricted`.
- `NoopContactsStore` for previews/tests.
- `NSContactsUsageDescription` added to the `info.properties` block in `apple/project.yml` for both targets.
- `com.apple.security.personal-information.addressbook` added to `apple/CabalmailMac/CabalmailMac.entitlements`.
- Tests in `CabalmailKit/Tests/CabalmailKitTests/ContactsStoreTests.swift` against a fake `CNContactStore`-shaped protocol seam: cache hit, name lookup, photo lookup, denied-permission graceful degradation.
- No UI change yet. Wiring into the app happens in Phase 2.

Acceptance: `swift test` green, app builds for iOS and macOS, no behavior change.

### Phase 2: read-side enrichment

- Inject the `ContactsStore` into `AppState` (or a sibling environment object) so views can read it.
- `MessageListView+Rows.swift` `senderLabel`: when the envelope's `from.first.displayName` is nil, fall back to `ContactsStore.displayName(for:)` before showing the mailbox. Use a `.task(id:)` keyed on the address so the row updates if Contacts changes underneath us.
- `MessageDetailView` header: same pattern for the `From` line.
- `AvatarView.swift`: insert contact-photo lookup ahead of the existing BIMI fetch. New precedence: contact photo (if Contacts granted and a match exists) -> BIMI -> initials. The existing BIMI plumbing is untouched; it just runs second. The view's `bimiAttempted` gating becomes "remoteSourceAttempted" and resolves the contact-photo path first.

Acceptance: with Contacts populated and authorized, opening a message from a known contact shows their name in the list and their photo in the detail header. Denying permission, or no match, leaves the existing behavior unchanged.

### Phase 3: compose autocomplete (suggestion list)

- New `ComposeRecipientSuggestionsView` rendered immediately below each of the To / Cc / Bcc text fields when that field is focused and non-empty.
- `ComposeViewModel` gains a `suggestions(forField:) -> [RecipientSuggestion]` computed property that filters `ContactsStore.allEntries()` (a new method that returns the per-email-address rows from the unified contacts store, deduped) against the current trailing token in the field. Match either by name prefix (case-insensitive, word-boundary) or by email substring.
- Tapping a suggestion replaces the trailing token in the field with `\"Name\" <addr@host>, ` and re-focuses the field. Comma is the canonical separator; the existing send-time recipient parse already handles it.
- No token-field UIView wrapping in this phase. The user still sees plain text in the field; the suggestions list is the entire autocomplete UX. Promotion to a real token field is its own follow-on, not blocking.

Acceptance: typing `joh` in To with John Doe in Contacts shows a suggestion row; tapping it produces `"John Doe" <jdoe@example.com>, ` in the field and the message sends correctly.

### Phase 4: contact picker sheet

- A small Contacts-glyph button next to each recipient field (To / Cc / Bcc) opens a sheet.
- iOS / visionOS: wrap `CNContactPickerViewController` in `UIViewControllerRepresentable`. Configure `displayedPropertyKeys = [CNContactEmailAddressesKey]` so the picker shows emails as the selectable rows.
- macOS: wrap `CNContactPicker` (`NSViewControllerRepresentable`).
- The sheet returns one or more `(name, email)` pairs; the compose view appends each as `\"Name\" <addr@host>` to the field the button belongs to.
- Permission denied: the sheet shows the standard "Open Settings" affordance the OS provides; we don't reimplement it.

Acceptance: tapping the picker glyph next to To and selecting two contacts appends both as formatted recipients.

### Phase 5: `mailto:` handler

- `apple/project.yml`: add `CFBundleURLTypes` for scheme `mailto`, role `Editor`, to both targets' `info.properties`.
- New `CabalmailKit/Sources/CabalmailKit/Compose/MailtoURL.swift`: pure parser for RFC 6068 `mailto:` URLs. Handles `to` (in the path), `?cc=`, `?bcc=`, `?subject=`, `?body=`, percent-decoding, multiple comma-separated recipients per slot. Discards unknown headers (the RFC's `&in-reply-to=` etc.) for now — we can add what we need when we need it.
- `CabalmailApp.swift` (iOS/visionOS) and `CabalmailMacApp.swift` (macOS) gain `.onOpenURL { handleMailto($0) }`. The handler routes through the existing compose-launch helper that the New Message button already uses, with the parsed fields pre-filled.
- macOS only: document in `docs/setup.md` (or wherever the operator-facing setup lives) that selecting Cabalmail as the default mail app is a one-time user action in System Settings -> General -> Default Web Browser / Mail. iOS exposes the same setting under Settings -> Mail -> Default Mail App on iOS 14+.

Acceptance: clicking `mailto:test@example.com?subject=Hi&body=Hello` in another app opens Cabalmail to a new compose window with the recipient, subject, and body pre-populated.

## Risks and open questions

- **Limited contacts access (iOS 18+).** `requestAccess` no longer guarantees full-book access; the user can pick a subset. Our autocomplete and the contact picker both need to work with the limited set without leaking which contacts were withheld. The picker honors this automatically; the suggestion list just returns the subset.
- **Concurrency on `CNContactStore`.** The framework is thread-safe in principle but unifyContacts-style queries can be slow on large books. The actor isolation pattern keeps reads off the main thread; the cache absorbs repeat lookups in scrollable lists.
- **macOS sandbox + Contacts.** The entitlement gates the framework even on user grant. Confirm the App Store reviewer-facing usage string is consistent with the in-app prompt; mismatches have been a rejection cause historically.
- **Photo size.** `CNContact.thumbnailImageData` is the right field for the 40pt avatar; `imageData` is full-resolution and unnecessary. Decoding a thumbnail is cheap; we still cache the decoded `Data` to avoid re-fetching from `CNContactStore` for repeated rows.
- **Display-name spoofing.** A sender can put anything in their `From` display name. We currently render whatever the envelope says; with this change, if Contacts has a name for the address, the Contacts name wins. That's the correct precedence — the user's own address book is the trusted source — but it does mean a stranger who happens to share an email address with a contact (unlikely but possible after a domain change) inherits the contact's name. Acceptable.
- **mailto: hijacking.** Registering as a handler is harmless on its own; the user still has to elect Cabalmail as default. No security implications.

## Out of this plan

- A real SwiftUI token field with chip rendering and per-recipient delete. The suggestion list ships first; chips are a Phase 3.5 polish that can come after the rest of the contacts story is in place.
- Group contacts (`CNGroup`). The current scope is per-email enrichment; group expansion in the compose field can come later.
- Surfacing the "set as default mail app" prompt inside Cabalmail itself (some clients do this on first launch). Out of scope; let the OS settings own it.
