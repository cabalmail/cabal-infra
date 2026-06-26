- Added BIMI publishing for Cabalmail's own mail. New addresses now get a
  `default._bimi` TXT record (and the `mail-admin` system sender gets one via
  Terraform) pointing at an SVG Tiny PS rendering of the Cabalmail mark, so
  receivers that support BIMI display our logo. Records are written per
  sending subdomain because the lookup name puts the subdomain in the middle,
  where a DNS wildcard cannot reach.
