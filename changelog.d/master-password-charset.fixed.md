- The generated IMAP master password now guarantees at least one
  character from every class the Cognito default password policy
  requires. A draw without a digit (seen bootstrapping development)
  wedged every subsequent apply at the master Cognito user. Note: the
  pinned minimums force a one-time master-password rotation on existing
  environments at their next apply; SSM and Cognito rotate together,
  with a seconds-scale mismatch window mid-apply.
