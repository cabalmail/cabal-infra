- **Read-only MCP server for AI agents.** `POST /mcp` lets an MCP client
  such as Claude Code read one mailbox with three tools (`list_folders`,
  `list_messages` with unread/from/subject/text/date filters, and
  `get_message`), authenticated by a `cbl_agt_` bearer token instead of
  Cognito. The owner mints, lists and revokes tokens through the new
  `new_agent_grant`, `list_agent_grants` and `revoke_agent_grant` endpoints
  (or `scripts/agent-grant.py`); only each token's SHA-256 is stored, in
  the new `cabal-agent-grants` table. A REQUEST Lambda authorizer
  (`authorize_agent`, result TTL 0, so revocation is immediate) resolves the
  token to its grant, and the `mcp` Lambda opens folders with `EXAMINE` and
  fetches `BODY.PEEK[]`, so reading never marks mail read; its role has no
  DynamoDB or S3 access. Phase A grants cover INBOX only and expire within a
  year. See `docs/agent-access.md`.
