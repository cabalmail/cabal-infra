# Agent access (MCP)

Cabalmail exposes one mailbox to an AI agent through a [Model Context Protocol](https://modelcontextprotocol.io) server at `POST /mcp` on the existing API. An MCP client connects in one of two ways: Claude Code and other clients that take a static header use a bearer token the mailbox owner mints, and claude.ai (web, desktop and mobile) signs in with the owner's Cabalmail login over OAuth. Either way it can list folders, list or filter messages, read a message, view its attachments and inline images, and see its flags. Reading never marks a message read.

Access is read-only unless the grant is `read_flag`. A `read_flag` grant can also add the owner's own custom flags (the ones in their flag palette, such as "Follow up") to messages, and nothing else: it cannot remove a flag, set a system flag such as read or deleted, create a flag, move, delete, send or reply.

This is Phase A of the [agent mail access plan](./1.x/agent-mail-access-plan.md), plus the OAuth sign-in from its Phase C and the add-a-flag part of Phase B. The plan holds the design rationale and what comes next.

## What an agent can do

| Tool | What it returns |
|---|---|
| `list_folders` | The folders the grant covers. Phase A grants cover `INBOX` only. |
| `list_messages` | Envelopes newest first (id, date, from, to, cc, subject, unread, flagged, custom flags by label, size, has attachments), paged with `limit` (max 50) and `offset`. Optional filters: `unread_only`, `from`, `subject`, `text`, `since`, `before`. |
| `get_message` | One message by id: headers, its custom flags, the sender-authentication verdicts, the body as text (HTML is converted, capped at `max_chars`, default 20,000), and its attachments and inline images, each with the `part` number `get_attachment` takes, its name, type, size and whether it is inline. |
| `get_attachment` | One attachment or inline image by message id and `part`. JPEG, PNG, GIF and WebP images up to 3 MB come back as MCP image content the model can look at (the type is read from the bytes, not the label); text attachments come back as text, capped at `max_chars`. Other types are refused. |
| `list_flags` | The owner's custom flags, as label and keyword. Given a message id, also that message's custom flags, unread and flagged state. |
| `add_flag` | `read_flag` grants only; a `read_only` grant is not offered it. Adds one custom flag, by label (case-insensitive) or keyword, to up to 50 messages. Reports which ids were flagged and which were not found. |

Every tool result carries an `untrusted_content` notice, and the server's `instructions` tell the model that mail is written by its sender and is data, not instructions. That is advisory. The real control is what the server cannot do: there is no tool that sends mail, moves or deletes it, or removes anything, so a message that talks an agent round can at worst get it to read what the owner already granted and, with a `read_flag` grant, add one of the owner's own flags.

### Body repairs

`get_message` undoes two sender faults seen in real mail. Some senders (USPS Informed Delivery, for one) wrap the text part twice, so its content starts with a second `Content-Type:` / `Content-Transfer-Encoding:` block; that block is removed, and its encoding applied if it names one. Some bulk senders (Mandrill, for one) build the plain-text alternative from the HTML and leave the stylesheet in, so it opens with CSS rules; when it does, the HTML part is used instead, or the rules are stripped if there is no HTML. Line endings come back as `\n`.

### Custom flags

A custom flag is stored on the message as one of the fixed keywords `cabal-flag-01` to `cabal-flag-20`; its label and color live in the owner's flag palette (synced preferences), exactly as the native and web clients keep them ([rules-composition plan](./1.x/rules-composition-and-custom-flags-plan.md), decisions 4 and 6). The MCP server reads the palette to show labels and to resolve `add_flag`'s argument, and refuses any keyword that is not a slot in the palette, as `set_flag` does. Flags are created, renamed and deleted only in the clients.

## How it works

```
MCP client --(POST /mcp, Authorization: Bearer cbl_agt_...)--> API Gateway
  --> authorize_agent (REQUEST authorizer)  looks the token's hash up in cabal-agent-grants
  --> mcp Lambda                            IMAP as the grant's user: EXAMINE for reads,
                                            a read-write SELECT only for add_flag
```

Requests from claude.ai carry a Cognito access token instead of a `cbl_agt_` token; see [Connect claude.ai](#connect-claudeai) for that path. Everything after the authorizer is the same.

- **Tokens** look like `cbl_agt_` followed by 43 URL-safe characters. Only the SHA-256 of a token is stored, as the hash key of `cabal-agent-grants`, so the plaintext is shown once at mint time and can never be recovered. A lost token is revoked and a new one minted.
- **Grants** are per Cognito user, at most 10 live at a time, and expire after 1 to 365 days (default 90). They cover `INBOX` and are `read_only` (the default) or `read_flag`. `read_write` is reserved for moving mail and cannot be minted yet.
- **Revocation is immediate.** The authorizer's result cache is off (TTL 0), so a revoked or expired grant is refused on the next request.
- **Reads change nothing.** Every read selects its folder with `EXAMINE` and fetches bodies with `BODY.PEEK[]`. The one write, `add_flag`, is a `UID STORE +FLAGS` of a palette slot on a read-write selection, and it is offered only to `read_flag` grants and checked again in the handler. The Lambda's IAM role has no S3, Route 53, SNS, SQS or Cognito access, and of DynamoDB only `GetItem` on `cabal-user-preferences`, for the palette. Folder scope is checked in the Lambda as well as at mint time.
- **Transport** is stateless streamable HTTP: every JSON-RPC message is one POST with one JSON response, no session id and no server-sent stream (a GET gets 405). Supported protocol versions are 2025-11-25, 2025-06-18 and 2025-03-26.
- **Limits.** `mcp/POST` is throttled to 5 requests a second with a burst of 10, below the stage-wide default, because each call opens an IMAP session.

## Setting it up

The route deploys with the rest of the stack: merging to `stage` or `main` runs `app.yml` (which builds and uploads the new Lambda zips) and `infra.yml` (which creates the table, the two Lambdas, their roles and the route). No manual AWS step is needed.

### Mint a token

Grants are minted by the signed-in mailbox owner through the Cognito-authenticated `/new_agent_grant` endpoint. There is no screen for it in the clients yet; use the script, which signs in the way the webmail does and needs no AWS credentials:

```
export CABALMAIL_USERNAME='<your username>'
export CABALMAIL_PASSWORD='<your password>'
./scripts/agent-grant.py --control-domain example.net --totp 123456 \
    mint --label "Claude Code on my laptop" --days 30
```

Add `--access read_flag` to let the agent add your custom flags too. It prints the token on stdout (once), and on stderr the `/mcp` URL and a ready-made command to register the server with Claude Code. `list` shows your grants with their state and when each was last used; `revoke <grant id>` ends one.

### Connect Claude Code

```
claude mcp add --transport http cabalmail \
    https://<api-id>.execute-api.<region>.amazonaws.com/<stage>/mcp \
    --header "Authorization: Bearer cbl_agt_..."
```

Any MCP client that accepts a static bearer header works the same way. The URL is the API's invoke URL (the `invokeUrl` in `https://admin.<control-domain>/config.json`) with `/mcp` appended.

### Connect claude.ai

claude.ai custom connectors cannot send a static `Authorization` header, so claude.ai signs in through the Cognito Hosted UI instead, with the same username, password and TOTP code as the webmail. No token is minted for it.

1. Find the two values.
   - **Server URL:** the `invokeUrl` in `https://admin.<control-domain>/config.json`, with `/mcp` appended. Don't copy the `mcp_url` output from the infra workflow's run summary: the region is a masked secret in CI, so it shows there as `***`. Locally, `terraform output mcp_url` prints it in full.
   - **Client ID:** the `mcp_oauth_client_id` output on the infra workflow's run summary, or the `cabal_mcp_client` entry under the user pool's app clients in the Cognito console.
2. In claude.ai, open **Settings > Connectors**, choose **Add custom connector**, and enter:
   - **Name:** `Cabalmail` (any name works).
   - **Remote MCP server URL:** the server URL from step 1, `https://<api-id>.execute-api.<region>.amazonaws.com/<stage>/mcp`.
   - Under **Advanced settings**, **OAuth Client ID:** the client ID from step 1. Leave **OAuth Client Secret** empty: the client is public and uses PKCE.
3. Choose **Connect**. claude.ai opens the Cabalmail sign-in page on `<pool domain>.auth.<region>.amazoncognito.com`; sign in there. The connector then shows the tools, `add_flag` included.

A connector added on claude.ai on the web is also available in the Claude desktop and mobile apps. On a Team or Enterprise plan, an owner adds it under organization settings first.

How the sign-in works:

- A request to `/mcp` without a valid token gets a 401 whose `WWW-Authenticate` header points to `https://admin.<control-domain>/.well-known/oauth-protected-resource` (RFC 9728). That document names `https://admin.<control-domain>` as the authorization server, whose `/.well-known/oauth-authorization-server` document (RFC 8414) points at the Hosted UI's authorize, token and revoke endpoints. Both are static JSON on the admin site, because Cognito serves neither document in the form MCP clients need.
- `cabal_mcp_client` allows only the authorization code flow, only claude.ai's callback (`https://claude.ai/api/mcp/auth_callback`) as a redirect URI, and only the scopes `cabal-mcp/mail.read` and `cabal-mcp/mail.flag`. It has no `openid` or admin scope, and the rest of the API, which expects ID tokens, refuses its tokens. Both scopes are advertised in the discovery documents, so claude.ai asks for both, and the Hosted UI shows no consent screen: connecting claude.ai gives it `read_flag` access.
- `authorize_agent` verifies the access token's signature against the pool's published keys and checks its issuer, `token_use`, client ID, expiry and the read scope. A token that passes is INBOX-only, and `read_flag` if it also carries `cabal-mcp/mail.flag`, else `read_only`. It has no row in `cabal-agent-grants`, so it does not appear in `agent-grant.py list`.
- A connector signed in before `mail.flag` existed holds tokens with the read scope only, and refreshing does not add a scope. It keeps working read-only; to get `add_flag`, disconnect and connect it again.
- Access tokens last 15 minutes and claude.ai refreshes them quietly. The refresh token lasts 7 days, after which claude.ai asks you to sign in again.

To disconnect, remove the connector in claude.ai. To cut off a session you no longer control, an operator runs `aws cognito-idp admin-user-global-sign-out --user-pool-id <pool id> --username <user>`, which revokes the user's refresh tokens on every client, the webmail and native apps included. An access token already issued keeps working for up to 15 minutes, because the authorizer checks it locally rather than asking Cognito on every call.

Claude Code cannot use this sign-in, because Cognito needs every redirect URI registered in advance and Claude Code's local callback port varies. Keep using a minted token there.

## Operating it

- **Audit log.** The mcp Lambda writes one JSON line per tool call to `/cabal/lambda/mcp`: grant id, user, tool, folder, message id (and part, for `get_attachment`), outcome and duration; for `add_flag`, the message ids and the flag as given. It never logs message content or search terms. Refused tokens are logged by the authorizer in `/cabal/lambda/authorize_agent` by grant id only, never by token, and a refused OAuth token by its reason (for example `wrong client` or `expired`). Calls made over OAuth log the grant id as `oauth-` followed by the token's session id.
- **claude.ai says the connector needs attention.** Its refresh token expired or was revoked; choose **Connect** again and sign in. If sign-in itself fails, check that the user has TOTP set up, since the pool's sign-in trigger applies to the Hosted UI too.
- **claude.ai signs in, then says authorization failed.** If `/cabal/lambda/authorize_agent` shows `refused oauth token reason=oauth not configured`, the authorizer has none of its `MCP_OAUTH_*` environment variables. The AWS provider leaves them out of any plan in which one of their values is not yet known, such as the run that first creates `cabal_mcp_client` (or replaces it). Run the infra workflow once more; that plan sets them.
- **A token stopped working.** Run `agent-grant.py list`: the grant shows as `revoked` or `expired`, or is gone (expired rows are removed by the table's TTL). Mint a new one.
- **IMAP maintenance.** While `/cabal/maintenance/imap` is active, tool calls return an error result with the retry hint rather than failing the request.
- **Backups.** `cabal-agent-grants` is deliberately outside the backup plan: a lost grant is re-minted in a minute, and a restore could bring back a token its owner revoked.

## Not yet

- A grant-management screen in the native clients (the API is client-agnostic).
- Removing flags, system flags, `move_messages` (`read_write` grants) and folders beyond INBOX. See the plan's Phasing section.
- Attachments other than images and text (PDFs, office files).
- A per-token rate limit; the method throttle above stands in for now.
