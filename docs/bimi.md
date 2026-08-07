# BIMI: sender logos

Cabalmail participates in [BIMI](https://bimigroup.org/) in both directions: clients display senders' published logos, and every Cabalmail address publishes one.

## Displaying senders' logos

The `fetch_bimi` Lambda resolves a sender domain to a logo defensively, since the input is attacker-controlled DNS and SVG (`lambda/api/fetch_bimi/function.py`):

- DNS TXT lookup at `default._bimi.<from-domain>`, falling back to the organizational domain (Public Suffix List).
- The `l=` logo URL must be https; fetched with a 32 KB cap and redirects disabled.
- The SVG is validated (no DOCTYPE/entities, no scripts, no external references), then rasterized to a 96 px PNG with a bundled `resvg` binary — clients never see the original SVG.
- Results cache 24 h at `bimi/<domain>.png` in the `cache.<control_domain>` bucket; the endpoint returns a presigned URL or `{"url": null}`, never a 5xx.

The Apple clients layer avatars: initials, then Contacts photo, then BIMI logo (`AvatarView`). The web client uses initials then BIMI.

## Publishing your own

Every minted address subdomain (and `mail-admin`) gets a `default._bimi` TXT record in its canonical DNS set, pointing at `https://www.<control_domain>/assets/bimi/cabalmail.svg`. The logo source is `front-door/assets/bimi/cabalmail.svg` in this repo, deployed by `app.yml`'s front-door job; replace it with your own BIMI-compliant SVG to brand outbound mail. Suspend and revoke withdraw the BIMI record along with the rest of the address's DNS; the admin dashboard's DNS repair republishes it.

**No VMC.** Cabalmail does not provision a Verified Mark Certificate (~$1500/yr, and it requires a trademarked logo). Receivers that require one (notably Gmail) will not display the mark; receivers that accept bare BIMI (e.g. Fastmail) will. If you buy one, [caa.md](./caa.md) covers authorizing the mark-certificate CA. Design history: [0.9.x/bimi.md](./0.9.x/bimi.md).
