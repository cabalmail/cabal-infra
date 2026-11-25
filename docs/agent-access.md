# Agent access (read-only MCP)

Cabalmail exposes one mailbox to an AI agent through a read-only [Model Context Protocol](https://modelcontextprotocol.io) server at `POST /mcp` on the existing API. An MCP client such as Claude Code connects with a bearer token that the mailbox owner mints, and gets three tools: list folders, list or filter messages, and read a message. It cannot send, reply, move, delete, flag or mark anything, and reading a message does not mark it read.

This is Phase A of the [agent mail access plan](./tentative/agent-mail-access-plan.md), which holds the design rationale and what comes next.

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

## Operating it

- **Audit log.** The mcp Lambda writes one JSON line per tool call to `/cabal/lambda/mcp`: grant id, user, tool, folder, message id, outcome and duration. It never logs message content or search terms. Refused tokens are logged by the authorizer in `/cabal/lambda/authorize_agent` by grant id only, never by token.
- **A token stopped working.** Run `agent-grant.py list`: the grant shows as `revoked` or `expired`, or is gone (expired rows are removed by the table's TTL). Mint a new one.
- **IMAP maintenance.** While `/cabal/maintenance/imap` is active, tool calls return an error result with the retry hint rather than failing the request.
- **Backups.** `cabal-agent-grants` is deliberately outside the backup plan: a lost grant is re-minted in a minute, and a restore could bring back a token its owner revoked.

## Not yet

- A grant-management screen in the native clients (the API is client-agnostic).
- Attachment download, read-write grants (`set_flags`, `move_messages`) and folders beyond INBOX. See the plan's Phasing section.
- A per-token rate limit; the method throttle above stands in for now.
