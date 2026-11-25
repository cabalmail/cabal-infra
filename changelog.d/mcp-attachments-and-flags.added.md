- **Attachments and custom flags on the MCP server.** `get_attachment`
  returns an attachment or inline image by the part number `get_message` now
  lists: JPEG, PNG, GIF and WebP images up to 3 MB as MCP image content, text
  attachments as text. `list_flags` shows the owner's custom flags by label,
  and messages now report theirs. `add_flag` adds one of the owner's custom
  flags (palette slots only, add-only, at most 50 messages a call) and is
  offered only to grants with the new `read_flag` access level: a minted
  grant with `--access read_flag`, or a claude.ai sign-in carrying the new
  `cabal-mcp/mail.flag` scope. Read-only grants stay read-only. The mcp
  Lambda gains `GetItem` on `cabal-user-preferences` to read the palette.
