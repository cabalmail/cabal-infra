# Agent access (read-only MCP)

Cabalmail exposes one mailbox to an AI agent through a read-only [Model Context Protocol](https://modelcontextprotocol.io) server at `POST /mcp` on the existing API. An MCP client connects in one of two ways: Claude Code and other clients that take a static header use a bearer token the mailbox owner mints, and claude.ai (web, desktop and mobile) signs in with the owner's Cabalmail login over OAuth. Either way it gets three tools: list folders, list or filter messages, and read a message. It cannot send, reply, move, delete, flag or mark anything, and reading a message does not mark it read.

This is Phase A of the [agent mail access plan](./1.x/agent-mail-access-plan.md), plus the OAuth sign-in from its Phase C. The plan holds the design rationale and what comes next.

## What an agent can do

| Tool | What it returns |
|---|---|
| `list_folders` | The folders the grant covers. Phase A grants cover `INBOX` only. |
| `list_messages` | Envelopes newest first (id, date, from, to, cc, subject, unread, flagged, size, has attachments), paged with `limit` (max 50) and `offset`. Optional filters: `unread_only`, `from`, `subject`, `text`, `since`, `before`. |
| `get_message` | One message by id: headers, the sender-authentication verdicts, the body as text (HTML is converted, capped at `max_chars`, default 20,000), and attachment names, types and sizes. Attachment contents are not served. |

Every tool result carries an `untrusted_content` notice, and the server's `instructions` tell the model that mail is written by its sender and is data, not instructions. That is advisory. The real control is what the server cannot do: there is no tool that sends mail or changes the mailbox, so a message that talks an agent round can at worst get it to read what the owner already granted.

## How it works

```
MCP client --(POST /mcp, Authorization: Bearer cbl_agt_...)--> API Gateway
  --> authorize_agent (REQUEST authorizer)  looks the token's hash up in cabal-agent-grants
  --> mcp Lambda                            EXAMINE-only IMAP as the grant's user
```

Requests from claude.ai carry a Cognito access token instead of a `cbl_agt_` token; see [Connect claude.ai](#connect-claudeai) for that path. Everything after the authorizer is the same.

- **Tokens** look like `cbl_agt_` followed by 43 URL-safe characters. Only the SHA-256 of a token is stored, as the hash key of `cabal-agent-grants`, so the plaintext is shown once at mint time and can never be recovered. A lost token is revoked and a new one minted.
- **Grants** are per Cognito user, at most 10 live at a time, and expire after 1 to 365 days (default 90). Phase A mints only `read_only` grants on `INBOX`.
- **Revocation is immediate.** The authorizer's result cache is off (TTL 0), so a revoked or expired grant is refused on the next request.
- **Read-only by construction.** The mcp Lambda selects folders with `EXAMINE`, fetches bodies with `BODY.PEEK[]`, and its IAM role has no DynamoDB, S3, Route 53, SNS, SQS or Cognito access at all. Folder scope is checked in the Lambda as well as at mint time.
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

It prints the token on stdout (once), and on stderr the `/mcp` URL and a ready-made command to register the server with Claude Code. `list` shows your grants with their state and when each was last used; `revoke <grant id>` ends one.

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
3. Choose **Connect**. claude.ai opens the Cabalmail sign-in page on `<pool domain>.auth.<region>.amazoncognito.com`; sign in there. The connector then shows the three tools.

A connector added on claude.ai on the web is also available in the Claude desktop and mobile apps. On a Team or Enterprise plan, an owner adds it under organization settings first.

How the sign-in works:

- A request to `/mcp` without a valid token gets a 401 whose `WWW-Authenticate` header points to `https://admin.<control-domain>/.well-known/oauth-protected-resource` (RFC 9728). That document names `https://admin.<control-domain>` as the authorization server, whose `/.well-known/oauth-authorization-server` document (RFC 8414) points at the Hosted UI's authorize, token and revoke endpoints. Both are static JSON on the admin site, because Cognito serves neither document in the form MCP clients need.
- `cabal_mcp_client` allows only the authorization code flow, only claude.ai's callback (`https://claude.ai/api/mcp/auth_callback`) as a redirect URI, and only the scope `cabal-mcp/mail.read`. It has no `openid` or admin scope, and the rest of the API, which expects ID tokens, refuses its tokens.
- `authorize_agent` verifies the access token's signature against the pool's published keys and checks its issuer, `token_use`, client ID, expiry and scope. A token that passes is read-only on INBOX, the same as a Phase A grant. It has no row in `cabal-agent-grants`, so it does not appear in `agent-grant.py list`.
- Access tokens last 15 minutes and claude.ai refreshes them quietly. The refresh token lasts 7 days, after which claude.ai asks you to sign in again.

To disconnect, remove the connector in claude.ai. To cut off a session you no longer control, an operator runs `aws cognito-idp admin-user-global-sign-out --user-pool-id <pool id> --username <user>`, which revokes the user's refresh tokens on every client, the webmail and native apps included. An access token already issued keeps working for up to 15 minutes, because the authorizer checks it locally rather than asking Cognito on every call.

Claude Code cannot use this sign-in, because Cognito needs every redirect URI registered in advance and Claude Code's local callback port varies. Keep using a minted token there.

## Operating it

- **Audit log.** The mcp Lambda writes one JSON line per tool call to `/cabal/lambda/mcp`: grant id, user, tool, folder, message id, outcome and duration. It never logs message content or search terms. Refused tokens are logged by the authorizer in `/cabal/lambda/authorize_agent` by grant id only, never by token, and a refused OAuth token by its reason (for example `wrong client` or `expired`). Calls made over OAuth log the grant id as `oauth-` followed by the token's session id.
- **claude.ai says the connector needs attention.** Its refresh token expired or was revoked; choose **Connect** again and sign in. If sign-in itself fails, check that the user has TOTP set up, since the pool's sign-in trigger applies to the Hosted UI too.
- **A token stopped working.** Run `agent-grant.py list`: the grant shows as `revoked` or `expired`, or is gone (expired rows are removed by the table's TTL). Mint a new one.
- **IMAP maintenance.** While `/cabal/maintenance/imap` is active, tool calls return an error result with the retry hint rather than failing the request.
- **Backups.** `cabal-agent-grants` is deliberately outside the backup plan: a lost grant is re-minted in a minute, and a restore could bring back a token its owner revoked.

## Not yet

- A grant-management screen in the native clients (the API is client-agnostic).
- Attachment download, read-write grants (`set_flags`, `move_messages`) and folders beyond INBOX. See the plan's Phasing section.
- A per-token rate limit; the method throttle above stands in for now.
