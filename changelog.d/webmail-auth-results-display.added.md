- Webmail now displays the SPF/DKIM/DMARC authentication verdicts stamped
  on inbound mail: messages that could not be authenticated as coming from
  their claimed sender get a warning indicator in the message list, and
  the reading view shows a per-method chip line (muted "Not verified" for
  mail that predates the feature or bypassed the inbound relay).
