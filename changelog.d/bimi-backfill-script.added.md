- **BIMI backfill script.** `scripts/backfill-bimi-records.py` publishes the
  standard `default._bimi` TXT record for address subdomains created before
  BIMI publishing shipped. It reads the domain map and control domain from
  the deployed `new` Lambda, skips subdomains whose DNS is not live, leaves
  any existing BIMI record untouched, and is a dry run unless `--apply` is
  passed. Intended to be run once per environment from CloudShell.
