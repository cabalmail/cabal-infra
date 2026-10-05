- **Messages in nested folders open on iPhone, iPad and Mac.**
  `/fetch_message` signed its link to the raw message for the folder path
  the client sent (`Parent/Child`), but the message is cached under the
  server's own path (`Parent.Child`), so for any message in a nested folder
  the link pointed at nothing. The Apple reader loads every body through that
  link and showed a server error instead, and the web app's View source
  failed the same way. The link now points at the cached copy.
