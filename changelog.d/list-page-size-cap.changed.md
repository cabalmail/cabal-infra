- The `/list_messages` `limit` page-size parameter is now bounded server-side:
  an explicit limit above 250 is clamped to 250 (a missing limit still returns
  the full sorted list, so the React virtualized view is unaffected). The Apple
  clients use this to fetch a larger page (200) while scrolling older mail --
  keeping the top page small for a fast first paint but cutting the number of
  `/list_envelopes` round trips on a deep scroll, where per-request IMAP
  connect/SELECT overhead dominates.
