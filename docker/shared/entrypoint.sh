#!/bin/bash
# Container entrypoint — Phase 2 will add runtime config generation.
# For now, render the sendmail.mc template and start supervisord.
set -euo pipefail

# ── Render sendmail.mc from template ─────────────────────────────
if [ -f /etc/mail/sendmail.mc.template ]; then
  sed "s/__CERT_DOMAIN__/${CERT_DOMAIN}/g" \
    /etc/mail/sendmail.mc.template > /etc/mail/sendmail.mc
fi

# ── Start services via supervisord ───────────────────────────────
exec /usr/bin/supervisord -c /etc/supervisord.conf
