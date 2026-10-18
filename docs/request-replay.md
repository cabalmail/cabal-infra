# Request replay: which requests the Apple clients send twice

The Kit sends every API, Cognito and presigned S3 request it makes through
`URLSessionHTTPTransport`
(`apple/CabalmailKit/Sources/CabalmailKit/Auth/HTTPTransport.swift`).
Two requests in the apps go around it and are never sent again: the
notification service's own `POST /push_envelope` (`URLSession.shared`, an
8 s timeout) and the BIMI logo, a presigned S3 URL that `AvatarView` loads
with `AsyncImage`.
When a request fails with a dropped connection
(`URLError.networkConnectionLost`, -1005), a timeout (-1001) or a cancel
URLSession made up on its own, the transport may send it once more after
250 ms. This page lists every request the Kit makes and whether it gets
that second copy, with what a second copy does on the server and the line
each verdict rests on.

`RequestReplayPolicy.swift`, next to the transport, holds the rule.
`RequestReplayTableTests` drives every row below through the real
transport over a connection that drops once, and counts the attempts; its
rows live in `RequestReplayRows.swift`. Change a verdict in all three
places together.

## The rule

The transport can't tell whether the first copy reached the server. A
-1005 usually means the request never left a connection that had gone
stale, but sometimes the server did the work and the reply was lost. A
-1001 comes 60 seconds after the request went out (the Kit sets no
timeout of its own), and by then the first copy has usually run: the API
gives up on a Lambda after 29 seconds. So a second copy can land a quarter
of a second after the first, or a minute after it, and either way the
first may have done its work. A request is sent again only when that
second copy leaves the user no worse off than the failure would:

- it changes nothing the first didn't, or nothing the failure wouldn't
  leave behind anyway; and
- what it answers points the user at the right next step.

A request that fails the test is sent once, and its failure reaches the
caller as `CabalmailError.network` ("Couldn't reach the server"), which is
true: the client doesn't know what happened. A second copy that answered
"already exists" or "changed on another device" for a change the first
copy made would not be.

The policy reads a request in this order:

1. A presigned S3 URL (an `X-Amz-Signature` or `Signature` query item):
   GET and PUT are sent again. This comes first because the URL's last
   path component is the user's file name, which could spell an
   endpoint's.
2. A Cognito request (host `cognito-idp.*`, header `X-Amz-Target:
   AWSCognitoIdentityProviderService.<Operation>`): by operation, as in
   the Cognito table.
3. Any other GET: sent again.
4. Anything else: sent again only when its endpoint, the URL's last path
   component, is marked below. An endpoint with no row is sent once.

A caller that cancels during the 250 ms wait gets
`CabalmailError.cancelled`, and no second copy is sent.

The Debug Log names each decision under "HTTPTransport": `retrying PUT
move_messages after URLError -1005: …` or `not retrying PUT new_folder
after URLError -1005: a second copy isn't safe to send`. A presigned URL is
logged as `presigned S3 URL`, never by its file name.

## Adding an endpoint

A new write is sent once until it has a row here, a row in
`RequestReplayRows.swift` and, if it is sent again, an entry in
`RequestReplayPolicy.replaySafeWrites`. `RequestReplayTableTests` scans
`API/*.swift` for `post(`, `put(` and `delete(` calls and
`Auth/AuthService.swift` for Cognito operations, and fails on any with no
row, so adding the call makes the decision.

This table covers the transport's own retry, which lands within about a
minute of the first copy. A durable queue that replays a write minutes or
hours later (the outbox, the feed-state queue) needs more than this:
`mark_folder_read` is sent again here because a minute's worth of new
mail marked read is mild and reversible, not because marking whatever is
unread at replay time is safe.

A second copy that lands a minute late can also undo a change made in
between: a flag cleared again by a replayed set, a preference another
device changed put back. Those are reversible and need a timeout and a
second change inside the same minute. The rows where a late copy could
lose something for good, such as Empty Trash, are sent once.

## Lambda writes

Line numbers are in `lambda/api/` on `stage` at `e48e151`. "Again" means
the transport sends a second copy; "Once" means it doesn't.

| Endpoint | Kit call | What a second copy does | Verdict | Rests on |
| --- | --- | --- | --- | --- |
| `PUT /move_messages` | `moveMessages` | The UIDs have left the source; answers 200 with the same body. Checked on stage on 2026-10-17, with and without `mark_seen`. | Again | `move_messages/function.py:44-52`; `_shared/helper.py:478`, `:583` |
| `PUT /set_flag` | `setFlag` | Sets or clears a flag already set or cleared; 200, same body (stage, 2026-10-17). | Again | `set_flag/function.py:90-94` |
| `DELETE /purge_messages` | `purgeMessages` | UID EXPUNGE of UIDs already gone; 200 (stage, 2026-10-17). | Again | `purge_messages/function.py:33-36` |
| `DELETE /empty_trash` | `emptyTrash` | Flags and expunges everything in Trash at the time it runs. Up to a minute late, that includes mail deleted after the user confirmed, gone for good. | Once | `empty_trash/function.py:29-33` |
| `PUT /mark_folder_read` | `markFolderRead` | Marks whatever is unseen when it runs: nothing, or mail that arrived since the first copy, up to a minute's worth. Reversible. | Again | `mark_folder_read/function.py:44-60` |
| `PUT /send` | `sendMessage` | The Message-Id was claimed by the first: 200 `duplicate` once delivered, 409 `duplicate_in_flight` while the first runs, which the client queues. No second delivery. | Again | `send/function.py:42`, `:252-307` |
| `PUT /save_draft` (save) | `saveDraft` | Appends a second copy; the reply names it and the client adopts it, so the first stays in Drafts. A failure leaves the same stray copy, because the next save appends afresh, so the retry is no worse and answers the truth. | Again | `save_draft/function.py:77-80`, `:96` |
| `PUT /save_draft` (discard) | `discardDraft` | Expunges a UID already gone, under the UIDVALIDITY guard; 200 either way. | Again | `save_draft/function.py:113-129` |
| `PUT /upload_url` | `requestAttachmentUploads` | Mints a fresh set of keys and URLs and stores nothing; the client uses the set it receives. | Again | `upload_url/function.py:27`, `:89` |
| `PUT /new_folder` | `createFolder` | The folder exists: 409 "A folder called X already exists" for the folder the first copy made. | Once | `new_folder/function.py:21-23` |
| `DELETE /delete_folder` | `deleteFolder` | The folder is gone: 404 "There is no folder called X", and the sidebar keeps the row. | Once | `delete_folder/function.py:22-24` |
| `PUT /subscribe_folder` | `subscribeFolder` | Subscribes a subscribed folder; Dovecot answers OK. | Again | `subscribe_folder/function.py`; `_shared/helper.py:1229` |
| `PUT /unsubscribe_folder` | `unsubscribeFolder` | Unsubscribes an unsubscribed folder; OK. | Again | `unsubscribe_folder/function.py`; `_shared/helper.py:1236` |
| `POST /new` | `newAddress` | Finds the address the first copy created, the caller's, and answers 201 with nothing written (since 1.31.2). | Again | `new/function.py:105-117` |
| `DELETE /revoke` | `revokeAddress` | The row is gone: 403 "Address not associated with authenticated user", and the address stays in the list. | Once | `_shared/helper.py:298-320` |
| `PUT /suspend_address` | `suspendAddress` | Already suspended: 200 with nothing done. | Again | `suspend_address/function.py:24-26` |
| `PUT /reinstate_address` | `reinstateAddress` | Not suspended: 200 with nothing done. | Again | `reinstate_address/function.py:22-24` |
| `PUT /set_favorite` | `setFavorite` | Adds to or removes from a set; same end state. | Again | `set_favorite/function.py:42-53` |
| `PUT /set_preferences` | `updateDisplayName`, `saveAppPreferences` | Writes the same values per key. | Again | `set_preferences/function.py:278-281`, `:317-339` |
| `PUT /set_nav_state` | `saveNavState` | Replaces the cursor with the same cursor; only the timestamp moves. | Again | `set_nav_state/function.py:184` |
| `PUT /set_rules` | `setRules` | The version moved on: 409 "Rules changed on another device; reload." for the save the first copy made. | Once | `set_rules/function.py:311-316`, `:347-353` |
| `PUT /confirm_user` | `confirmUser` | The account is confirmed: Cognito refuses to confirm it again, and the Lambda answers 500 for the confirm the first copy made. | Once | `confirm_user/function.py:17`; `_shared/admin_limits.py` (`admin_user_action_response`) |
| `PUT /enable_user` | `enableUser` | Enables an enabled user, which Cognito accepts; 200. | Again | `enable_user/function.py:17` |
| `PUT /disable_user` | `disableUser` | Disables a disabled user, which Cognito accepts; 200. | Again | `disable_user/function.py:17` |
| `DELETE /delete_user` | `deleteUser` | The user is gone: Cognito finds no such user, and the Lambda answers 500 for the delete the first copy made. | Once | `delete_user/function.py:39` |
| `PUT /set_user_domain_access` | `setUserDomainAccess` | Writes the same grant row, or deletes one already gone; same end state. | Again | `set_user_domain_access/function.py:67`, `:69` |
| `POST /push_register` | `registerPushDevice` | The same upsert. | Again | `push_register/function.py:201` |
| `POST /push_deregister` | `deregisterPushDevice` | Deletes a row already gone, which the Lambda answers as success. | Again | `push_deregister/function.py:4`, `:44` |
| `POST /push_envelope` | `fetchPushEnvelope` | A read sent as POST: read-only IMAP, a cache fill. | Again | `push_envelope/function.py:107` |
| `POST /rss_subscribe` | `subscribe` | Usually finds the subscription and answers `existing`, but a copy that overlaps a slow first one can add a second subscription. | Once | `_shared/rss_subscribe_core.py:196-204` |
| `POST /rss_unsubscribe` | `unsubscribe` | After the first has finished: 404 `unknown_subscription` for an unsubscribe that worked. A copy that overlaps the first: the row's delete is conditional, so whichever copy's delete removes the row detaches the subscriber and answers 200, and the other answers 404. | Once | `rss_unsubscribe/function.py` (`handler`, `delete_subscription`); `_shared/rss_api.py` (`get_subscription`) |
| `PUT /rss_update_subscription` | `updateSubscription` | The same SET and REMOVE on the same row. | Again | `rss_update_subscription/function.py` (`handler`) |
| `POST /rss_new_folder` | `newFolder` | Makes a second folder with the same name and a new id. | Once | `rss_new_folder/function.py:25`, `:33` |
| `PUT /rss_update_folder` | `updateFolder` | The same SET and REMOVE on the same row. | Again | `rss_update_folder/function.py:15-56` |
| `POST /rss_delete_folder` | `deleteFolder` | The folder is gone: 404 `unknown_folder`. | Once | `rss_delete_folder/function.py:22` |
| `POST /rss_set_item_state` | `setItemState` | Writes the same flags. | Again | `rss_set_item_state/function.py:20-40` |
| `POST /rss_mark_all_read` | `markAllRead` | Carries the tap-time watermark, so it writes nothing new. | Again | `rss_mark_all_read/function.py` (`handler`) |
| `POST /rss_opml_import` | `importOpml` | Finds everything the first copy imported and reports "0 created", and a copy that overlaps the first can duplicate folders and feeds. | Once | `rss_opml_import/function.py:41-93` |

The rows marked Once whose second copy only answers a misleading error
(`/new_folder`, `/delete_folder`, `/revoke`, `/set_rules`, `/confirm_user`,
`/delete_user`, `/rss_delete_folder`) could be sent again if the call site learned that its
request had been replayed and read that error as "the first copy landed".
Nothing tells it today. The other Once rows (`/empty_trash`,
`/rss_subscribe`, `/rss_unsubscribe`, `/rss_new_folder`,
`/rss_opml_import`) are not candidates: their second copy can do work of its
own. Of two overlapping `/rss_unsubscribe` copies, the one that answers 404
has already cleared the caller's read state for the feed, which matters if
the feed was re-subscribed in between; a copy that arrives after the first
has finished changes nothing.

## Reads

Every GET is sent again: `/list`, `/list_my_domains`, `/list_users`,
`/list_user_domain_access`, `/fetch_bimi`,
`/list_folders`, `/folder_status`, `/list_messages`, `/list_envelopes`,
`/search_envelopes`, `/fetch_message`, `/list_attachments`,
`/fetch_attachment`, `/fetch_inline_image`, `/get_preferences`,
`/get_nav_state`, `/get_rules`, `/rss_list_subscriptions`,
`/rss_list_items`, `/rss_get_item`, `/rss_opml_export`, and the
`config.json` fetch at launch. Some write to a cache, or mark the message
seen when asked to; a second copy writes the same thing.

## Presigned S3

| Request | What a second copy does | Verdict |
| --- | --- | --- |
| `GET` of the raw message's presigned URL (`fetchPresignedData`) | Reads the same bytes; the URL lasts 24 hours (`_shared/helper.py:1334`). | Again |
| `PUT` of an attachment to an `/upload_url` URL (`uploadAttachment`) | Writes the same bytes to the same key. Past the URL's 120 s it answers 403 instead. | Again |

## Cognito

Every Cognito call is a POST to one URL, so the policy reads the
operation from `X-Amz-Target`. Only the first three rows are reachable
from the shipped apps. The rest are Kit API that no Apple screen calls yet
(auth-parity B2 plans the sign-up screens; no plan yet schedules a
password-reset or authenticator screen), and their verdicts are the
defaults such a screen inherits. How Cognito answers a second copy is
service behaviour, from its documentation and not checked on stage; the
error each answer becomes is in `AuthService.swift`, and the refresh row's
rotation setting is in `terraform/infra/modules/user_pool/main.tf`.

| Operation | Kit call | What a second copy does | Verdict |
| --- | --- | --- | --- |
| `InitiateAuth` (password) | `signIn` | A second, independent sign-in: new tokens or a new challenge. The first set is orphaned and expires. For a user with an SMS second factor (no flow turns one on today) it also texts a second code, for the session the client keeps, so the first text's code may be refused; signing in again after a failure would send that second text too. | Again |
| `InitiateAuth` (refresh) | `refreshIdToken`, and a stale token on any call | A second token pair from the same refresh token. Refresh-token rotation is off; turning it on would need this row checked again. | Again |
| `RespondToAuthChallenge` | `submitMfaCode` | The challenge session is single-use: "session expired", sign in again. A failure would ask the same, and the retry saves the likelier case, a first copy lost on a connection that went stale while the user typed the code. | Again |
| `GetUser` | `totpEnabled` | A read sent as POST. | Again |
| `SetUserMFAPreference` | `confirmTotpEnrollment`, `disableTotp` | Sets the same preference. | Again |
| `SignUp` | `signUp` | `UsernameExistsException` for the account the first copy made. | Once |
| `ConfirmSignUp` | `confirmSignUp` | The user is already confirmed: `NotAuthorizedException`, which reads as a bad password. | Once |
| `ResendConfirmationCode` | `resendConfirmationCode` | Sends a second code, which may replace the first. | Once |
| `ForgotPassword` | `forgotPassword` | Sends a second reset code, which may replace the first. | Once |
| `ConfirmForgotPassword` | `confirmForgotPassword` | The code is used: an error for a reset that worked. | Once |
| `AssociateSoftwareToken` | `beginTotpEnrollment` | Issues a second secret; the reply carries it. Likely harmless, but not documented, and no screen calls it yet. | Once |
| `VerifySoftwareToken` | `confirmTotpEnrollment` | Probably refused as a used code, after a verification that worked. | Once |
