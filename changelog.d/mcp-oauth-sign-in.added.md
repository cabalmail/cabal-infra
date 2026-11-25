- **OAuth sign-in for the MCP server, for claude.ai custom connectors.**
  claude.ai can now connect to `POST /mcp` by signing in through the Cognito
  Hosted UI, since its custom connectors cannot send a static
  `Authorization` header. A new public app client, `cabal_mcp_client`
  (authorization code with PKCE, claude.ai's callback only, no secret), is
  limited to a new resource-server scope, `cabal-mcp/mail.read`. The admin
  site serves static RFC 9728 protected-resource and RFC 8414
  authorization-server documents under `/.well-known/`, and an API-wide
  `UNAUTHORIZED` gateway response adds the
  `WWW-Authenticate: Bearer resource_metadata=...` challenge that starts the
  flow. `authorize_agent` verifies these access tokens locally against the
  pool's JWKS (signature, issuer, `token_use`, client, expiry, scope) and
  grants them the same read-only INBOX access as a Phase A grant, with no
  grant row. Minted `cbl_agt_` tokens keep working and remain the way in for
  Claude Code. New Terraform outputs `mcp_url` and `mcp_oauth_client_id`
  give the two values claude.ai asks for. The agent mail access plan moved
  from `docs/tentative/` to `docs/1.x/`.
