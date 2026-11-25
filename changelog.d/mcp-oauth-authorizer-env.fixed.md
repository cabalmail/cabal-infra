- **OAuth sign-in to the MCP server was refused after a successful login.**
  The release that added the sign-in created the `cabal_mcp_client` app
  client and set `authorize_agent`'s OAuth environment variables in the same
  apply, and the AWS provider dropped the variables from that plan because
  the new client ID was not yet known. `authorize_agent` therefore ran
  without them and refused every Cognito access token as "oauth not
  configured", which claude.ai reported as "Authorization failed" right
  after showing the connector as connected. This change only documents the
  quirk next to the variables; merging it re-runs the infra workflow, whose
  plan now sees the known client ID and sets the variables.
