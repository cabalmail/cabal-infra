- **Inbound mail from an address under the control domain is no longer
  refused.** The VPC held a Route 53 private hosted zone named for the whole
  control domain, so inside the VPC it answered authoritatively for every name
  below it while holding records for only ten of them. Every address
  subdomain of the control domain was therefore NXDOMAIN there, and sendmail's
  sender-domain existence check made `smtp-in` answer `553 5.1.8 ... Domain of
  sender address ... does not exist` to any remote MTA presenting one of those
  addresses as the envelope sender - a forwarder, a mailing list preserving
  the original sender, a remote auto-reply or a bounce. OpenDKIM and OpenDMARC
  were shadowed for the same names and stamped such mail `dkim=none` /
  `dmarc=none` against our own published policy. The zone carried no
  information the public zone did not: all eight of its non-structural records
  were byte-identical copies of their public siblings, so it is retired rather
  than narrowed, and the three mail-authentication mirrors added as a
  workaround for the same shadow go with it.
