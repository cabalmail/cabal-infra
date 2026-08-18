- **IMAP tier requires TLS and trusts only loopback.** Dovecot on the `imap`
  container now sets `ssl = required` instead of `ssl = yes`, and its
  `login_trusted_networks` narrows from the NLB public-subnet CIDRs to
  `127.0.0.1`. Both settings existed to let the load balancer's
  TLS-terminated 993 listener forward plain TCP to 143 and still
  authenticate; that listener was removed in 0.11.x, and every consumer now
  dials 143 and issues STARTTLS before LOGIN. This closes the residual
  allowance that anything in the public subnets could attempt plaintext auth.
  The in-container IMAPS listener on 993 is switched off and its task-def
  port mapping and `LOGIN_TRUSTED_NETWORKS` env are gone.
