- **Mail authentication resolves from inside the VPC.** The VPC private zone is
  named for the control domain, so it shadowed the public zone's SPF, DKIM and
  DMARC records for every VPC-internal lookup. Every address subdomain points
  its mail authentication at those names (SPF `include:`, DKIM and DMARC
  CNAMEs), so `smtp-in` resolved no DMARC policy and stamped inbound mail
  `dmarc=none (p=none)` while the published policy was `p=reject`. The private
  zone now carries the same three records, taken from the public ones so the
  two cannot drift.
