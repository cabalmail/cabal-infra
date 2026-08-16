- **Reserved infrastructure labels refused on both address-create endpoints.**
  `/new` refuses to put an address on one of the control domain's
  infrastructure labels (`admin`, `www`, `imap`, `smtp`, `smtp-in`, `smtp-out`,
  `mail-admin`), where the record would either collide with an existing CNAME or
  overwrite an auth record. The admin "create on behalf of a user" endpoint
  reached the same Route 53 change through its own copy of the create path and
  carried no such check. Both endpoints now apply one shared guard, and that
  guard additionally refuses `mail-admin` on *every* mail domain, not just the
  control domain: it is the subdomain the system sender is provisioned on, and
  an address there could send mail that DKIM-signs and SPF-aligns exactly like
  a Cabalmail notification.
