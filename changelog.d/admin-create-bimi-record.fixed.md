- **BIMI record published for admin-created addresses.** The admin
  address-create endpoint published four of the five canonical address DNS
  records, omitting the `default._bimi` TXT, so mail sent from an address
  created that way carried no Cabalmail mark — until a suspend/reinstate cycle
  silently added the record it never had. Both create paths now publish the
  canonical record set from one place, so a record added in future cannot reach
  only one of them.
