- **Certificate renewal ready for shorter Let's Encrypt lifetimes.** The
  mail tiers' certificate renewal now runs daily instead of every 60 days
  and renews once half the current certificate's lifetime has passed,
  reading the lifetime off the certificate itself. The 60-day cadence would
  have left 4 days of margin on the 64-day certificates Let's Encrypt
  issues from February 2027 and let the 45-day ones from February 2028
  expire outright; daily runs also retry a failed issuance the next day.
  The Healthchecks `certbot-renewal` check moves to a daily period with a
  3-day grace. Invoke the Lambda with `{"force": true}` to renew early.
