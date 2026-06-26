- Fixed sender BIMI logos never loading in the clients. The `fetch_bimi`
  endpoint is now a spec-correct, defensive proxy: it discovers the logo at
  the From domain and then the organizational domain, validates the SVG, and
  rasterizes it to a PNG (cached and served as a presigned URL) so SwiftUI's
  `AsyncImage`, which cannot decode SVG, can render it. It no longer crashes
  on non-BIMI TXT records or returns a guessed `favicon.ico`.
