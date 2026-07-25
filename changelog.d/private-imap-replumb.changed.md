- **API Lambdas reach IMAP privately.** The IMAP-consuming Lambdas (every
  API endpoint plus append_sent and process_dmarc) now run inside the VPC
  and dial the imap container directly over its Cloud Map name - STARTTLS
  on 143, verifying the tier certificate end-to-end - instead of the
  public IMAPS listener. New S3 and DynamoDB gateway endpoints keep the
  message cache and address-table traffic off the NAT path. First step
  toward closing public IMAP access entirely.
