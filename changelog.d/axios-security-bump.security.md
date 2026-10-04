- **Admin app's `axios` dependency bumped to 1.20.0.** Resolves seven high
  severity advisories affecting versions before 1.20.0: a Node HTTP adapter
  prototype-pollution gadget enabling request socket hijack (CVE-2026-101905),
  an unenforced `maxRedirects: 0` in the fetch adapter enabling redirect-based
  SSRF (CVE-2026-101907), a ReDoS in the `data:` URL parser (CVE-2026-101903),
  a ReDoS in proxy-bypass host normalization reachable via a redirect
  `Location` header (CVE-2026-101906), a prototype-pollution gadget in
  `toFormData` options (CVE-2026-101909), an HTTP/2 adapter that bypassed
  configured DNS lookup and proxy controls (CVE-2026-101898), and an
  unhandled `error` event during HTTP/2 session initialization that could
  crash the process (CVE-2026-101901).
