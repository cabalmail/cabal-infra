- **A NIL header-fields section no longer fails a whole envelope page.** When
  the mail server answered the fetch's header section with NIL rather than a
  literal, `/list_envelopes` (and `/search_envelopes`, by the same shared
  code) returned a 502 for every message in the page instead of the one
  affected envelope's headers coming back empty.
