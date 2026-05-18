# Folder/address list polish across clients

Status: planned. Forward-looking; supersede with the as-shipped notes once each phase lands.

## Goals

1. Folder lists everywhere show two sections: **Subscribed** (top) and **All folders** (below, inclusive of subscribed).
2. Address lists everywhere (sidebar + compose From picker) show two sections: **Favorites** (top) and **All addresses** (below, inclusive of favorites).
3. Apple clients gain affordances for subscribing/unsubscribing folders.
4. Apple clients gain affordances for favoriting/unfavoriting addresses.
5. Apple clients gain a sidebar with tabs for **Folders** and **Addresses**; tapping an address filters the message list to mail sent to that address (parity with the React sidebar).

"Favorite address" is a brand-new concept and is stored server-side so it syncs across web and native clients.

## Non-goals

- No change to address creation/revocation flow.
- No change to how IMAP subscription works under the hood — we already have `subscribe_folder`/`unsubscribe_folder` Lambdas; we're just exposing them in Apple.
- No reordering within sections beyond the existing alphabetical/server order (Phase 2 can revisit if needed).

## Data model: favorites

New attribute on `cabal-addresses` rows: `favorite` (boolean, default false / absent). DynamoDB is schemaless so no table migration; existing rows without the attribute are treated as `favorite=false`.

New Lambda `lambda/api/set_favorite/` with API Gateway route `POST /set_favorite` (Cognito-authorized). Body: `{ "address": "...", "favorite": true|false }`. Updates the row's `favorite` attribute; 404 if the address isn't owned by the caller.

`lambda/api/list/` extended to include `favorite` on each returned row.

## Phases

Each phase is independently shippable. Phases 1-2 can go through stage -> main on their own; phases 3-5 layer onto them.

### Phase 1: backend foundation

- New `lambda/api/set_favorite/function.py`.
- Extend `lambda/api/list/function.py` to surface `favorite`.
- Terraform in `terraform/infra/modules/app/`: new Lambda resource, API Gateway route, IAM, SSM wiring matching the existing `new`/`revoke` pattern.
- CHANGELOG entry under the active Unreleased section.

Acceptance: `curl` against the deployed stage API can flip the attribute and `list` reflects it.

### Phase 2: React parity

- `ApiClient.setFavorite(address, favorite)`.
- Sectioned rendering of address lists in: sidebar address list, compose From picker. Both inclusive in the "All" section.
- Star (or equivalent) toggle on each address row; optimistic update with rollback on error.
- Sectioned rendering of folder lists (Subscribed / All). The React app already drives subscription, so this is purely a presentation change.

Acceptance: web client shows both sectioned lists and can toggle favorites; reload preserves state.

### Phase 3: Apple data layer

`CabalmailKit/Sources/CabalmailKit/IMAP/` and the API-backed adapter:

- Extend the protocol that currently holds folder ops to include `subscribeFolder(_:)` / `unsubscribeFolder(_:)`. Implement in `ApiBackedImapClient` against the existing endpoints. `LiveImapClient` (still compiles even though prod doesn't use it) gets matching IMAP-level implementations to keep parity and tests honest.
- New address-side capability (whether a new client type or an addition to the existing one, decide at implementation time — leaning toward a separate `AddressClient` protocol since favoriting isn't IMAP): `setFavorite(address:favorite:)`, plus surfacing `favorite` on the existing address-list model.
- Tests in `CabalmailKit/Tests/` against fake transports for each new method.

Acceptance: `swift test` green; no UI change yet.

### Phase 4: Apple folder UI

- Sectioned folder list (Subscribed / All).
- Subscribe/unsubscribe affordance — swipe action on iOS, context menu on macOS (and a matching control on visionOS).
- Optimistic toggle with rollback on error, consistent with the React behavior.

Acceptance: folder subscription state round-trips between web and native within a refresh cycle.

### Phase 5: Apple address UI + sidebar tabs

- Introduce a tab control at the top of the existing sidebar with two tabs: **Folders** and **Addresses**. Folders tab shows the Phase 4 list; Addresses tab shows the new sectioned address list (Favorites / All).
- Favorite/unfavorite affordance on each address row (swipe action on iOS, context menu on macOS).
- Tapping an address sets a message-list filter scoped to that address (envelope `To` match, mirroring how the React sidebar narrows the inbox view). Persist the active filter the same way the currently-selected folder is persisted.
- Clearing the filter: switching folders, or an explicit "clear" affordance on the active address chip in the message-list header.

Acceptance: native sidebar matches the React sidebar's behavior — folder selection and address-scoped filtering both work and survive app relaunch.

## Risks and open questions

- **Address-filter semantics.** React's filter is "messages whose `To` (or `Cc`?) includes this address." Confirm the exact match rule by reading the React implementation before Phase 2, and reuse it verbatim in Phase 5.
- **Apple sidebar on iPhone.** The current Apple sidebar already handles compact layouts; adding tabs shouldn't change that, but verify the iPhone navigation stack still feels right after Phase 5.
- **Favorite on a revoked address.** `revoke` should clear the attribute implicitly (the row is deleted), so nothing to do — but worth a test in Phase 1.
- **Concurrency.** Two clients toggling favorite simultaneously: last-write-wins is fine for this UX; no conditional writes needed.

## Out-of-scope follow-ups

- Reordering favorites/subscribed entries by drag.
- Per-address notification preferences (would build naturally on top of the favorite attribute, but not part of this work).
