- **Orphaned BIMI record on revoke.** Revoking a subdomain's last address
  deleted its MX/SPF/DKIM/DMARC records but left the `default._bimi` TXT
  record behind (published since the BIMI Phase C rollout). Revoke now
  removes the full record set, and builds deletes from the records actually
  live in the zone, so addresses predating BIMI (or partially-removed sets)
  no longer risk failing the whole change batch.
