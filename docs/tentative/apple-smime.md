# Apple S/MIME (tentative)

**Status:** Tentative design exploration, not on the roadmap. Written 2026-06-14.
Nothing here is committed work; it exists to capture the shape of the problem
and a defensible path so the idea can be picked up — or dismissed — without
re-deriving the analysis.

This document covers **S/MIME on the native Apple clients only**. The reasoning
for that scope, and for choosing S/MIME over PGP, is in
[Scope and non-goals](#scope-and-non-goals).

## Why this is feasible at all

The system is a thin client over a trusted server: the Lambda API holds the
master IMAP/SMTP credential, fetches and parses every message, caches the raw
body in S3, and *composes* outbound MIME from decomposed fields
([`lambda/api/send/function.py`](../../lambda/api/send/function.py),
[`lambda/api/_shared/compose.py`](../../lambda/api/_shared/compose.py)). End-to-end
crypto wants the opposite: a server that never sees plaintext and never touches
a private key. Those two postures look irreconcilable, but for the Apple clients
the gap is already mostly closed:

- **Inbound is raw today.** `ApiBackedImapClient.fetchBody` ignores the server's
  pre-parsed `message_body_html`/`message_body_plain` and pulls the full RFC 5322
  bytes from the `message_raw` presigned URL, then parses MIME *client-side* with
  [`MimeParser`](../../apple/CabalmailKit/Sources/CabalmailKit/MIME/MimeParser.swift).
  That parser already names `S/MIME, PGP/MIME` as its one intentional gap — this
  design fills it.
- **Outbound has a builder.** The unused-on-the-API-path
  [`MessageBuilder`](../../apple/CabalmailKit/Sources/CabalmailKit/SMTP/MessageBuilder.swift)
  already emits RFC 5322 wire bytes (multipart/alternative, multipart/mixed,
  base64 attachments, RFC 2047 headers). Signing/encryption wraps its output.
- **A Keychain store exists.**
  [`SecureStore`](../../apple/CabalmailKit/Sources/CabalmailKit/Auth/SecureStore.swift)
  already persists the Cognito tokens and IMAP password in the data-protection
  keychain. Private-key custody extends this pattern (with a stronger access
  class — see [Key and certificate management](#key-and-certificate-management)).

The one thing people fear — that the server "sees everything" so encryption is
pointless — does not actually block the body. **Standard S/MIME does not encrypt
the outer headers.** From/To/Subject/Date/Message-ID/In-Reply-To/References stay
in cleartext. So the server-side envelope and threading parsing
([`/list_envelopes`](../../lambda/api/list_envelopes/function.py),
[`envelope_dict`](../../lambda/api/_shared/helper.py)) keeps working unchanged,
and caching the raw bytes in S3 is harmless when those bytes are ciphertext. The
metadata the server retains is exactly the metadata S/MIME exposes anyway.

## Scope and non-goals

**In scope:** S/MIME signing, signature verification, encryption, and decryption
in the shared CabalmailKit, surfaced in the iOS/visionOS and macOS apps.

**Out of scope, deliberately:**

- **The React web app.** Even with a key store, the server *serves the
  JavaScript and `/config.js` that would run the crypto*. A compromised or
  coerced server can ship backdoored JS that exfiltrates the key or the
  plaintext — the classic in-browser-PGP objection. "E2E" in a server-delivered
  web app is theater. Real E2E only holds in a distributed, signed native
  binary with Keychain-held keys. If web parity is ever required, the most the
  web app should claim is *verify-only* (validate a signature, never hold a
  private key), and even that is weak. This document does not design it.
- **PGP.** S/MIME wins here for one decisive reason: native interop. Apple Mail,
  iOS Mail, and Outlook all do S/MIME out of the box, so mail the Apple client
  signs or encrypts "just works" for mainstream recipients with no plugin. PGP
  buys CA-free key exchange but near-zero native support and a vendored OpenPGP
  dependency. Revisit only if the actual correspondent set is PGP-committed.
- **Header protection / "memory hole" encrypted subjects.** Possible later;
  adds complexity and interop sharp edges. Not phase one.
- **Server-side or gateway crypto.** Holding the user's private key on the
  server would be easy and is *pointless for confidentiality* — the server
  already reads all unencrypted mail. It is explicitly rejected. Keys live only
  on the client.

## Threat model

What this buys, stated honestly so nobody over-trusts it:

| Property | With client-held S/MIME keys |
|---|---|
| Confidentiality of **encrypted** message **bodies** | Protected from the server and anyone with IMAP/S3 access. |
| Authenticity / integrity of **signed** mail | Verifiable end to end. |
| Message **metadata** (who, when, subject, thread) | **Not** protected. Cleartext by S/MIME design; the server sees it regardless. |
| **Unencrypted** mail | Unchanged — server reads and can forge it. Encryption protects only the messages you choose to encrypt. |
| Key compromise via the server | The server cannot reach a Keychain-held private key, but it still controls delivery: it can drop, withhold, or inject *unsigned* mail. Signing is what defeats injection; encryption defeats reading. |

The compromises you accept are narrow: the server still sees metadata (true of
every S/MIME deployment) and still holds the master credential (so unencrypted
mail is as exposed as today). What you do **not** compromise is the thin-client
model for normal mail — it stays exactly as-is. Crypto is an additive lane
beside it, not a rewrite.

## Design overview

Add a **raw-passthrough lane** alongside the existing field-based path. Normal
mail keeps flowing through `compose_from_body` / pre-parsed `fetch_message`
exactly as today. Crypto mail takes a path where the client owns the bytes end
to end and the server is a dumb pipe:

```
                       NORMAL MAIL (unchanged)
  client fields ──▶ /send (compose_from_body) ──▶ SMTP
  /fetch_message (server-parsed body) ──▶ client renders

                       S/MIME MAIL (new lane)
  client builds+signs/encrypts RFC822 ──▶ /send_raw (verbatim) ──▶ SMTP
  /fetch_message message_raw (ciphertext) ──▶ client decrypts+parses+renders
```

The inbound half already exists for Apple (it consumes `message_raw`); only the
*crypto* step is new. The outbound half needs one new server endpoint that
submits client-built bytes without touching them.

## Inbound: verify and decrypt

The fetched raw bytes route through a new pre-pass before `MimeParser`:

1. **Detect.** Sniff the top-level Content-Type:
   - `multipart/signed; protocol="application/pkcs7-signature"` — detached
     signature (the common, interop-friendly form; the body stays readable to
     non-S/MIME clients).
   - `application/pkcs7-mime; smime-type=signed-data` — opaque signed.
   - `application/pkcs7-mime; smime-type=enveloped-data` — encrypted.
2. **Decrypt** (enveloped-data): find the recipient-matching key in the
   Keychain, unwrap the content-encryption key, decrypt to an inner RFC 5322
   message, then feed *that* back through `MimeParser` and render normally.
3. **Verify** (signed-data / multipart/signed): check the CMS signature against
   the signer cert and a trust policy, harvest the signer's certificate into the
   recipient-cert cache (this is the primary way we learn correspondents' certs —
   see [Key and certificate management](#key-and-certificate-management)), then
   parse and render the signed content with a verified/unverified badge.

Two concrete `MimeParser` touch points:

- **Raw part bytes.** Signature verification needs the *exact* original bytes of
  the signed part — its MIME headers and body, undecoded, canonical CRLF.
  `MimeParser` currently decodes transfer-encoding eagerly; it needs to also
  expose the verbatim byte range of each part so the verifier sees what was
  actually signed.
- **Re-entrancy.** Decrypting enveloped-data yields a fresh RFC 5322 message
  that must go through the same parse + render pipeline (including nested
  multipart, attachments, inline images). The parser is already recursive;
  this is feeding it a second buffer, not new traversal logic.

**Caching.** [`MessageBodyCache`](../../apple/CabalmailKit/Sources/CabalmailKit/Cache/MessageBodyCache.swift)
stores raw `.eml` bytes on disk. For encrypted mail that cache holds
*ciphertext*, which is fine and desirable. Decrypted plaintext must **not** be
written to that cache; it stays in memory for the lifetime of the view (or, if a
plaintext cache is ever wanted for performance, it needs its own
protected-data-class, evict-on-lock store — out of scope here).

The server's pre-parsed `message_body_html`/`message_body_plain` for an
encrypted message are just the PKCS#7 blob or empty; the Apple client already
ignores those fields, so no server change is needed for inbound.

## Outbound: sign and encrypt

The client builds the full message and hands the server opaque bytes:

1. Build the inner RFC 5322 message with the existing `MessageBuilder`.
2. **Sign** (detached): compute a CMS signature over the canonicalized inner
   part and wrap as `multipart/signed`. Prefer detached so recipients without
   S/MIME still read the body.
3. **Encrypt**: wrap the (optionally already-signed) message as
   `application/pkcs7-mime; smime-type=enveloped-data`, encrypting the
   content-encryption key to **each recipient's cert and the sender's own cert**
   (so the Sent copy is readable). Sign-then-encrypt is the usual order.
4. POST the finished bytes to the new `/send_raw`.

A naming note to avoid confusion:
[`SignatureFormatter`](../../apple/CabalmailKit/Sources/CabalmailKit/Compose/SignatureFormatter.swift)
is the *sig-block* (the "-- \nSent from..." trailer), unrelated to cryptographic
signing. Pick distinct type names (e.g. `SmimeSigner`) to keep them apart.

**Recipient cert availability is the real UX constraint.** S/MIME has no
universal directory. You can only encrypt to someone whose cert you already
hold, and certs realistically arrive two ways: harvested from signed mail they
sent you (step 3 of inbound), or manually imported. The compose UI must
therefore show per-recipient encryption availability and degrade gracefully:
sign-only when a recipient's cert is unknown, never silently send plaintext when
the user asked for encryption.

**Drafts.** [`/save_draft`](../../lambda/api/save_draft/function.py) composes
server-side today, so an encrypted draft can't use it as-is. Options, cheapest
first: (a) keep encrypted drafts **local only** (the `DraftStore` autosave buffer
already exists) and skip server draft sync for crypto messages in phase one;
(b) later, encrypt the draft to the sender's own cert and append the verbatim
bytes via a raw draft path. Phase one should take (a) and say so.

## Server changes

One new endpoint, deliberately minimal — a new function mirroring `/send`'s
auth and SMTP plumbing but **skipping composition entirely**:

- **`POST /send_raw`** accepts the client-built RFC 5322 message (base64 in the
  JSON body, or staged to S3 like attachments if size warrants) plus the
  envelope it needs for SMTP: `sender`, recipient list, `smtp_host`, `host`.
- It **must not** call `compose_from_body`, must not rewrite or inject headers,
  and must not run the CR/LF header-injection rewrite on body content (that
  check exists to sanitize *fields* the server assembles; here the client owns
  the whole message). It still validates `sender` against
  `user_authorized_for_sender` and still derives RCPT TO from the envelope it is
  given.
- It submits the bytes verbatim over the authenticated SMTP-OUT submission path,
  exactly as `send()` does after `send_message`.
- **Sent copy:** append the *same verbatim bytes* to Sent (so the stored copy is
  the real signed/encrypted message, decryptable because it was encrypted to the
  sender's own cert too). Reuse the existing S3-stage + `cabal-append-sent` SQS
  mechanism, passing the raw object rather than a server-composed one.
- **Idempotency:** keep the Message-Id dedupe claim, reading the id from the
  client-supplied bytes instead of generating it.

DKIM is unaffected — it is domain-level signing applied by SMTP-OUT and is
orthogonal to S/MIME's per-user signing. A message can be both DKIM-signed by
the domain and S/MIME-signed by the user.

Everything else server-side is untouched: envelope/threading parsing, folder
ops, search, and the entire normal-mail path.

## Key and certificate management

- **Own identity (private key + cert).** Import a PKCS#12 (`.p12`) via
  `SecPKCS12Import`, store the resulting identity as `kSecClassIdentity` in the
  data-protection keychain. Use a stronger access class than the token store's
  `kSecAttrAccessibleAfterFirstUnlock` — at least
  `...WhenUnlockedThisDeviceOnly`, and consider an access-control flag requiring
  device unlock/biometry for key use. The existing
  [`KeychainSecureStore`](../../apple/CabalmailKit/Sources/CabalmailKit/Auth/SecureStore.swift)
  is the pattern to follow but not the exact API (it stores generic-password
  blobs; identities are a different keychain class).
- **Provisioning the user's cert is out-of-band and orthogonal to the client
  work.** The client just imports a `.p12`. Where that cert comes from is a
  policy choice: a public S/MIME CA (some issue free personal certs), or a small
  self-run CA whose root the cabal trusts. A self-CA is fine within a closed
  group and painful with outside correspondents. This decision can be deferred;
  it does not gate the client implementation.
- **Recipient certs.** Maintain a recipient-cert cache, populated by harvesting
  signer certs from inbound signed mail and by manual import. Drives the
  compose UI's per-recipient "can encrypt" state.
- **Trust policy.** Decide how signer certs are validated: full X.509 chain to
  trusted roots, or trust-on-first-use pinning suited to a small group. TOFU is
  pragmatic for a cabal; chain validation is the "correct" answer. Surface the
  distinction in the verified badge rather than hiding it.

## The cross-platform crypto substrate (the main cost driver)

S/MIME messages are CMS (RFC 5652). The catch: **CMS encode/decode is
first-class on macOS** (`CMSEncoder` / `CMSDecoder`) **but those APIs are not
public on iOS/visionOS.** Since CabalmailKit is one shared package across both,
the CMS layer has to be a single implementation that works on all targets. The
realistic options:

1. **Vendor a mature C crypto library** (OpenSSL or BoringSSL via SwiftPM) and
   call its CMS/PKCS#7 routines. One code path on every platform; the cost is a
   C dependency, a binary-size bump, and the maintenance of pinning/updating it.
   Best for parity.
2. **Pure-Swift ASN.1 + your own CMS.** Apple's `swift-asn1` and
   `swift-certificates` give X.509 and ASN.1 but **not** CMS enveloped/signed
   data out of the box — you would build the CMS layer on top, plus the
   symmetric/asymmetric ops via `swift-crypto`/`SecKey`. No C dependency, but
   meaningfully more first-party crypto code to get exactly right (and crypto
   you write yourself is crypto you must get exactly right).
3. **Platform-split** (`CMSDecoder`/`CMSEncoder` on macOS, something else on
   iOS). Rejected: two crypto code paths to audit and keep in agreement is the
   worst of both.

This decision lands in phase zero because it underpins even verify-only, and it
dominates the effort estimate. Recommendation: **option 1** for a hobby-scale
system that values a small, auditable amount of *own* crypto code over avoiding
a vetted C dependency — but flag it as the key call to make before any code.

## Phasing and effort

Effort is relative (solo developer). The CMS-substrate decision above is
front-loaded into Phase 0 and is the single biggest variable.

| Phase | Scope | Server change | Private keys? | Rel. effort |
|---|---|---|---|---|
| **0** | Crypto substrate decision + inbound **verify** of signed mail; verified/unverified badge; harvest signer certs | none | no | Medium (substrate dominates) |
| **1** | Inbound **decrypt** of enveloped-data; render; keychain identity import; local-only encrypted drafts | none | yes | Medium |
| **2** | Outbound **sign + encrypt**; `/send_raw`; verbatim Sent copy; per-recipient cert availability in compose | `/send_raw` (small) | yes | Medium-large |
| (later) | Server draft sync for crypto mail; trust-policy hardening; header protection | raw draft path | yes | deferred |

Each phase ships standalone value: Phase 0 lets you *trust* signed mail you
receive without ever holding a key or changing the server; Phase 1 lets you
*read* encrypted mail; Phase 2 lets you *send* it. Stopping after any phase
leaves a coherent feature.

## Open decisions

1. **CMS substrate:** vendored C library vs. pure-Swift-on-`swift-asn1`. Gates
   everything. (Recommendation: vendored, above.)
2. **Cert provisioning:** public CA vs. self-run CA. Orthogonal to client code;
   needed before real-world use.
3. **Trust model:** X.509 chain validation vs. TOFU pinning for a small group.
4. **Web posture:** verify-only, or no S/MIME on web at all. (Recommendation: no
   web crypto; the in-browser threat model doesn't support the claim.)
5. **Encrypted drafts:** confirm local-only for phase one is acceptable, or
   pull the raw draft path forward.

## Related

- [`docs/draft-sync-and-threading.md`](../draft-sync-and-threading.md) — the
  existing Drafts lifecycle and threading-header plumbing that crypto drafts and
  signed-reply threading would build on.
- [`apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift`](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift)
  — the raw-fetch path the inbound design relies on.
