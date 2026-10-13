- **Very large folders open again.** A folder of roughly 140,000 messages or
  more failed to load with "Internal server error": the message-list
  endpoint's IMAP SORT response came back as a single line over Python
  imaplib's 1 MB line limit. The Lambda API now accepts lines up to 10 MB.
