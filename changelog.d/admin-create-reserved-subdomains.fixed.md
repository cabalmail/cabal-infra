- **Reserved control-domain labels refused on the admin address-create
  endpoint.** `/new` refuses to put an address on one of the control domain's
  infrastructure labels (`admin`, `www`, `imap`, `smtp`, `smtp-in`, `smtp-out`,
  `mail-admin`), where the record would either collide with an existing CNAME or
  overwrite an auth record. The admin "create on behalf of a user" endpoint
  reached the same Route 53 change through its own copy of the create path and
  carried no such check. Both endpoints now apply one shared guard.
