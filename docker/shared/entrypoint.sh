#!/bin/bash
# Container entrypoint — replaces Chef recipes with shell-based startup.
#
# Performs all runtime configuration that depends on environment variables
# or AWS service queries (DynamoDB, Cognito). Static config is baked into
# the image by the Dockerfile (Phase 1).
#
# The synchronous steps here are only what the tier's front-line listener
# needs before supervisord starts. The sendmail-side preparation (DynamoDB
# scan, sendmail.cf compile, aliases) lives in prepare-sendmail.sh: on the
# imap tier it runs as a supervisord program so Dovecot starts without
# waiting the 20-40s it takes, and on the smtp tiers — where sendmail IS
# the front-line listener — it runs inline at the end of this script.
# Either way sendmail-wrapper.sh blocks on the /run/sendmail-ready
# sentinel that prepare-sendmail.sh writes. Phase 3 of
# docs/0.10.x/imap-deploy-downtime-plan.md.
#
# Required env vars: TIER, CERT_DOMAIN, AWS_REGION, COGNITO_CLIENT_ID,
#                    COGNITO_POOL_ID, TLS_CA_BUNDLE, TLS_CERT, TLS_KEY
# Optional:          NETWORK_CIDR (VPC CIDR; smtp-out login_trusted_networks fallback)
#                    PREFLIGHT (=1: run all preparation steps, then exit 0
#                    instead of starting services - deploy validation)
#                    PUSH_QUEUE_URL (imap: consumed by the push-spool-drain
#                    supervisord program, not this script; see
#                    docs/0.11.x/push-notifications.md)
# IMAP-only:         MASTER_PASSWORD
# SMTP-OUT-only:     DKIM_PRIVATE_KEY
set -euo pipefail

# ── Validate required environment variables ─────────────────
missing=()
for var in TIER CERT_DOMAIN AWS_REGION COGNITO_CLIENT_ID COGNITO_POOL_ID \
           TLS_CA_BUNDLE TLS_CERT TLS_KEY; do
  if [ -z "${!var:-}" ]; then
    missing+=("$var")
  fi
done

if [ "${TIER:-}" = "imap" ] && [ -z "${MASTER_PASSWORD:-}" ]; then
  missing+=("MASTER_PASSWORD (required for imap tier)")
fi

if [ "${TIER:-}" = "smtp-out" ] && [ -z "${DKIM_PRIVATE_KEY:-}" ]; then
  missing+=("DKIM_PRIVATE_KEY (required for smtp-out tier)")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "[entrypoint] ERROR: Missing required environment variables:" >&2
  for var in "${missing[@]}"; do
    echo "  - $var" >&2
  done
  exit 1
fi

echo "[entrypoint] Starting $TIER tier configuration..."

# ── Step 1: TLS certificates ──────────────────────────────────
# Certs are injected via ECS task definition (Secrets Manager)
# and written to the paths sendmail/dovecot expect.
echo "[entrypoint] Writing TLS certificates..."
mkdir -p /etc/pki/tls/certs /etc/pki/tls/private /etc/opendkim/keys
echo "$TLS_CA_BUNDLE" > "/etc/pki/tls/certs/${CERT_DOMAIN}.ca-bundle"
echo "$TLS_CERT"      > "/etc/pki/tls/certs/${CERT_DOMAIN}.crt"
echo "$TLS_KEY"       > "/etc/pki/tls/private/${CERT_DOMAIN}.key"
chmod 600 "/etc/pki/tls/private/${CERT_DOMAIN}.key"

if [ "$TIER" = "smtp-out" ]; then
  echo "[entrypoint] Writing DKIM private key..."
  echo "$DKIM_PRIVATE_KEY" > /etc/opendkim/keys/cabal
  chmod 600 /etc/opendkim/keys/cabal
  chown opendkim:opendkim /etc/opendkim/keys/cabal

fi

# ── Step 2: Cognito auth script (imap + smtp-out only) ────────
# Replaces: chef/cabal/templates/default/cognito.bash.erb
# Used by PAM to authenticate IMAP/SMTP users against Cognito. smtp-in is a
# pure relay with no SMTP AUTH and no dovecot, so it never invokes this
# script - generating it there is dead work. It also breaks under the phase
# 2a cap drop: the file is chmod 100 (no owner write), so overwriting it on
# any entrypoint re-run needs DAC_OVERRIDE, which smtp-in no longer carries.
# Gate it to the tiers that actually authenticate.
if [ "$TIER" = "imap" ] || [ "$TIER" = "smtp-out" ]; then
  echo "[entrypoint] Generating cognito.bash..."
  cat > /usr/bin/cognito.bash <<COGNITO
#!/bin/bash

COGNITO_PASSWORD=\$(cat -)
COGNITO_USER="\${PAM_USER}"
AUTH_TYPE="\${PAM_TYPE}"

aws cognito-idp initiate-auth \\
  --region ${AWS_REGION} \\
  --auth-flow USER_PASSWORD_AUTH \\
  --client-id ${COGNITO_CLIENT_ID} \\
  --auth-parameters "USERNAME=\${COGNITO_USER},PASSWORD=\"\${COGNITO_PASSWORD}\""
COGNITO
  chmod 100 /usr/bin/cognito.bash
fi

# ── Step 3: Dovecot SSL config (IMAP + SMTP-OUT) ─────────────
# Replaces: chef/cabal/templates/default/dovecot-10-ssl.conf.erb
if [ "$TIER" = "imap" ] || [ "$TIER" = "smtp-out" ]; then
  echo "[entrypoint] Building full certificate chain for Dovecot..."
  cat "/etc/pki/tls/certs/${CERT_DOMAIN}.crt" \
      "/etc/pki/tls/certs/${CERT_DOMAIN}.ca-bundle" \
      > "/etc/pki/tls/certs/${CERT_DOMAIN}.chain.crt"

  echo "[entrypoint] Generating dovecot SSL config..."
  # Both tiers require TLS before any credential crosses the wire.
  #
  # SMTP-OUT tier: NLB does TCP passthrough for submission (587/465),
  # so Dovecot handles TLS directly.
  #
  # IMAP tier: this was "ssl = yes" (available but not required) for as
  # long as the NLB terminated TLS on 993 and forwarded plain TCP to 143,
  # because auth had to be allowed on that forwarded plain connection.
  # That listener is gone (#778/#779) and every consumer - the API
  # Lambdas, and so both clients - dials 143 and issues STARTTLS before
  # LOGIN (lambda/api/_shared/imap_session.py), so nothing legitimately
  # authenticates in the clear any more. "required" closes the residual
  # allowance rather than leaving it available to whatever else can reach
  # the port.
  _ssl_mode="required"
  cat > /etc/dovecot/conf.d/10-ssl.conf <<SSLCONF
ssl = ${_ssl_mode}
ssl_cert = </etc/pki/tls/certs/${CERT_DOMAIN}.chain.crt
ssl_key = </etc/pki/tls/private/${CERT_DOMAIN}.key
ssl_min_protocol = TLSv1.2
SSLCONF

  # Set Dovecot login_trusted_networks: the source networks whose sessions
  # count as "secured" for auth, and whose connect-and-drop probes stop
  # producing "Disconnected (no auth attempts)" log lines.
  #
  # SMTP-OUT tier: LOGIN_TRUSTED_NETWORKS is the NLB public-subnet CIDRs
  # (injected per-env by the task definition). It falls back to NETWORK_CIDR
  # (the whole VPC CIDR) so a missing/empty value fails OPEN - no lockout of
  # legitimate NLB-forwarded logins - rather than closed.
  #
  # IMAP tier: loopback only. The NLB's 993 listener is gone (#778/#779), so
  # the NLB forwards nothing here and the only thing that connects without
  # authenticating is the task definition's own TCP health check, which runs
  # inside the container. Trusting the public-subnet CIDRs was what made
  # "anything in the public subnets may attempt plaintext auth" true; with
  # ssl = required above and this list narrowed to 127.0.0.1, that allowance
  # is closed while the health-probe log suppression is kept.
  if [ "$TIER" = "imap" ]; then
    _login_trusted="127.0.0.1"
  else
    _login_trusted="${LOGIN_TRUSTED_NETWORKS:-${NETWORK_CIDR:-}}"
  fi
  if [ -n "${_login_trusted}" ]; then
    echo "[entrypoint] Setting Dovecot login_trusted_networks = ${_login_trusted}"
    cat > /etc/dovecot/conf.d/05-login.conf <<LOGINCONF
login_trusted_networks = ${_login_trusted}
LOGINCONF
  fi
fi

# ── Step 4: Create OS users from Cognito (imap + smtp-out only) ─
# Replaces: chef/cabal/recipes/_common_users.rb
#
# smtp-in is a pure relay: its mailertable routes every hosted-domain
# message to the imap container over SMTP (.tld -> smtp:[imap_host]) and it
# runs no dovecot, so it never resolves a local OS user. Skipping the sync
# there means smtp-in does no useradd/groupadd/install -o at startup, which
# lets its task definition drop CHOWN/FOWNER/DAC_OVERRIDE (phase 2a of
# docs/0.10.x/container-runtime-hardening-plan.md). imap delivers locally
# via procmail and smtp-out resolves submission auth against the system
# passwd db (dovecot userdb { driver = passwd }), so both still need them.
if [ "$TIER" = "imap" ] || [ "$TIER" = "smtp-out" ]; then
  echo "[entrypoint] Syncing users from Cognito..."
  /usr/local/bin/sync-users.sh
else
  echo "[entrypoint] Skipping user sync for $TIER (relay tier; no local users needed)."
fi

# ── Step 5: Dovecot master password (IMAP only) ──────────────
# Creates the master user for admin access to all mailboxes. Must run
# before Dovecot starts or the master-user auth path silently fails.
if [ "$TIER" = "imap" ]; then
  echo "[entrypoint] Setting dovecot master password..."
  htpasswd -b -c -s /etc/dovecot/master-users admin "${MASTER_PASSWORD}"
fi

# ── Step 5b: Push wake-signal spool (IMAP only) ───────────────
# procmail's push-enqueue.sh (run as the recipient user, with sendmail's
# sanitized environment and no AWS credentials) writes wake signals here;
# the push-spool-drain.sh supervisord program (root, full container env)
# forwards them to SQS. Sticky world-writable, like /tmp: any user may
# create signal files, none may delete another's; the drain daemon
# authenticates each file by owner. See docs/0.11.x/push-notifications.md.
if [ "$TIER" = "imap" ]; then
  echo "[entrypoint] Preparing push wake-signal spool..."
  mkdir -p /var/spool/cabal-push
  chmod 1777 /var/spool/cabal-push
fi

# ── Step 6: Prepare rsyslog working directory ─────────────────
echo "[entrypoint] Preparing rsyslog..."
mkdir -p /var/lib/rsyslog

# ── Step 7: Pin IMAP_INTERNAL_HOST in /etc/hosts (smtp-in only) ──
# Converts a transient Cloud Map outage from a permanent 5xx bounce
# ("Host unknown") into a queueable 4xx (TCP connection refused or
# timeout), which sendmail retries for ~4 days. `init` always leaves
# TARGET resolvable - the real IMAP IP when available, otherwise a
# last-known pin or the TEST-NET sentinel - so even a cold start during
# an IMAP outage defers rather than bounces. The companion `hosts-pin`
# daemon (started by supervisord) then converges the pin to the real IP
# within one poll interval. Smtp-in only; smtp-out keeps stock DNS so a
# user-typo'd external recipient still bounces fast.
if [ "$TIER" = "smtp-in" ]; then
  echo "[entrypoint] Pinning ${IMAP_INTERNAL_HOST:-imap.cabal.internal} in /etc/hosts..."
  /usr/local/bin/hosts-pin.sh init \
    || echo "[entrypoint] WARN hosts-pin init returned non-zero; daemon will converge the pin"
fi

# ── Step 8: Render inbound-auth milter configs (smtp-in only) ─
# opendkim (verify mode) and opendmarc (monitor mode) stamp
# Authentication-Results on inbound mail under the control-domain
# authserv-id (phase 1 of docs/0.10.x/inbound-auth-verification-plan.md).
# The config templates carry __CERT_DOMAIN__ placeholders; render them
# the same way prepare-sendmail.sh renders sendmail.mc. Render only, no
# chown: smtp-in's task definition drops CHOWN, so all ownership is set
# at image build time (see docker/smtp-in/Dockerfile).
if [ "$TIER" = "smtp-in" ]; then
  echo "[entrypoint] Rendering inbound-auth milter configs..."
  for _milter in opendkim opendmarc; do
    sed "s/__CERT_DOMAIN__/${CERT_DOMAIN}/g" \
      "/etc/${_milter}.conf.template" > "/etc/${_milter}.conf"
  done
fi

# ── Step 9: Sendmail preparation (smtp tiers only) ────────────
# Render sendmail.mc, generate maps from DynamoDB, compile sendmail.cf,
# and (on imap) assemble aliases. On the smtp tiers sendmail is the
# front-line listener, so this stays synchronous. On imap it is deferred
# to the [program:prepare-sendmail] supervisord program so Dovecot comes
# up first; until it finishes, smtp-in's deliveries to imap port 25 see
# connection refused and queue-and-retry, exactly as they do during the
# deploy gap itself. Phase 3 of docs/0.10.x/imap-deploy-downtime-plan.md.
if [ "$TIER" != "imap" ]; then
  /usr/local/bin/prepare-sendmail.sh once
fi

# ── Step 10: Pre-flight mode (deploy validation) ──────────────
# PREFLIGHT=1 is overlaid by the deploy pipeline's one-shot RunTask
# (deploy-ecs-service.sh) to exercise this entrypoint - secrets, EFS
# mount, Cognito, DynamoDB, sendmail compile - against a new image
# BEFORE the old IMAP task is stopped. Run the sendmail prep that the
# imap tier normally defers to supervisord, then exit 0 instead of
# starting services. A failure in any step above (set -e) stops the
# task non-zero and the deploy aborts with the old task still serving.
# Phase 5 of docs/0.10.x/imap-deploy-downtime-plan.md.
if [ "${PREFLIGHT:-0}" = "1" ]; then
  if [ "$TIER" = "imap" ]; then
    /usr/local/bin/prepare-sendmail.sh once
  fi
  echo "[entrypoint] PREFLIGHT complete; exiting without starting services."
  exit 0
fi

# ── Step 11: Start services via supervisord ───────────────────
echo "[entrypoint] Starting services via supervisord..."
exec /usr/local/bin/supervisord -c /etc/supervisord.conf
