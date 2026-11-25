- **MCP message bodies from badly built senders.** `get_message` no longer
  shows a stylesheet in place of the text when a sender's plain-text
  alternative was generated with its CSS left in (it uses the HTML part
  instead, or strips the rules), and no longer starts the body with
  `Content-Type:` lines when a sender nested a second MIME header block in
  the text part (the block is removed and its encoding applied). Body text
  now has `\n` line endings.
