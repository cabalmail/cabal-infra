- **Server chosen at runtime, not at build time.** The browser extension asks
  which Cabalmail server to use and remembers it per install, instead of
  having one compiled in, so a single build works against any deployment and
  can be pointed elsewhere from the popup. Host permissions follow: the
  extension now requests access to your server's origins once you name it,
  rather than holding broad access from the moment it is installed.
