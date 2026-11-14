# Synced settings

A user's settings follow their Cabalmail account between devices through one row per Cognito user in the `cabal-user-preferences` table, behind two endpoints: `GET /get_preferences` and `PUT /set_preferences`. This page is the contract for a client of those two endpoints.

## The row

- **Flat keys:** `theme`, `accent`, `density` (the web app's appearance) and `name` (the display name on outgoing mail).
- **`app`:** a map of string to string that holds the native clients' settings: reading and composing behaviour, the swipe bindings, the flag list (`flag_palette`, a JSON string), and one key per list for its remembered filter (`filter:mail:<folder>`, `filter:feeds:all`) and order (`order:feeds:all`). `set_preferences` validates every key and value and refuses the whole request with a 400 when one is unknown or invalid, writing nothing.
- **A version:** a count of the writes `set_preferences` has made to the row.

The navigation cursor (`/get_nav_state`, `/set_nav_state`) lives on the same row and is not part of this contract; writing it does not move the version.

## Reading

`GET /get_preferences` answers the flat keys (a default for each the row lacks), the `app` map (empty for an account that has never saved one), and `version` (0 for a row no counted write has touched). The read is consistent: it sees every write that was answered before it.

`version` is a top-level number. It is never inside `app`, whose values are all strings.

## Writing

`PUT /set_preferences` takes any of the flat keys and an `app` map, and **merges per key**: each key in the request is written, and every key the request does not name keeps its value. That holds inside `app` too. A client that sends only the keys it changed leaves the rest of the row alone.

Every write counts the version up by one, in the same update as the values, and the 200 answer carries the new `version` beside the values it wrote. A request whose `app` map is empty and that names no flat key writes nothing and answers no version.

## Saying which version a write was built on

A request may carry `expectedVersion`, a non-negative integer: the `version` the client last read or was last answered. The write then lands only if the row is still at that version (`0`: only if it has none).

When the row has moved on, nothing is written and the answer is a **409** whose body is the row as it is now, in the shape `GET /get_preferences` answers (flat keys, `app`, `version`), with an `Error` message beside it. The client takes that as its pull: it applies the answered values to every key it has not changed itself, keeps its own unsent changes, and sends again with the answered `version`.

A request without `expectedVersion` is written whatever the row holds. It still counts the version up, so a client that does send one sees that the row moved. Builds that predate the version send none and never get a 409.

Two cases worth knowing:

- **A second copy of a request that already landed** (a client that resends after a timeout) is answered 409 when it carried `expectedVersion`, because the first copy moved the row. The answered row holds the values the client sent, so there is nothing left for it to send.
- **A device that has never read the row** has no version to send. It reads first.

## The flag list

`flag_palette` is one key, so the per-key merge treats the whole list as one value: the last write of the list wins. A client that edits the list on an older copy of it would remove a flag another device added. `expectedVersion` is what prevents that: refused, the client merges its own edit into the answered list before it sends again.

A write that adds or deletes a flag of the user's own tells the mail tier, which recompiles the user's mail rules (see [Mail rules](./mail-rules.md)).

## Related reads of the row

`/set_flag` and `/rss_set_item_state` read the flag list before they put a flag of the user's own on a message or a feed item, and refuse a flag the list does not hold. Both reads are consistent, so a flag is usable from the moment the write that added it is answered.
