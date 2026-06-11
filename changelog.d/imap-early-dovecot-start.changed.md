- The IMAP container now starts Dovecot as soon as its prerequisites
  (TLS, Cognito auth script, user sync, master password) are ready,
  instead of behind the full sendmail preparation. The sendmail side
  (sendmail.mc render, DynamoDB map generation, sendmail.cf compile,
  aliases) moved to a prepare-sendmail.sh script that runs as a
  background supervisord program on imap and inline in the entrypoint on
  the smtp tiers; sendmail-wrapper.sh blocks on its /run/sendmail-ready
  sentinel and reconfigure.sh waits for it before processing changes.
  Cuts 20-40s of IMAP client downtime per deploy. Phase 3 of
  docs/0.10.x/imap-deploy-downtime-plan.md.
