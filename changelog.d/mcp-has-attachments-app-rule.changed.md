- **MCP message list counts attachments the way the apps do.**
  `list_messages`'s `has_attachments` now also counts a part whose type is
  `application` but which carries no disposition, the rule the Apple and
  Android clients use for their paperclip, so an assistant and the apps
  agree. Images shown inline in the body still do not count; the tool's
  description now says so and that `get_message` lists them.
