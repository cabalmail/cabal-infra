- The IMAP NLB target group now health-checks every 10s (was 30s), so a
  freshly deployed IMAP task enters service about 20s after Dovecot starts
  listening instead of up to 60s. The smtp target groups keep the 30s
  probe. Phase 1 of docs/0.10.x/imap-deploy-downtime-plan.md.
