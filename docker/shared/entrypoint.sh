#!/bin/bash
# Container entrypoint — replaces Chef recipes with shell-based startup.
#
# Performs all runtime configuration that depends on environment variables
# or AWS service queries (DynamoDB, Cognito). Static config is baked into
# the image by the Dockerfile (Phase 1).
#
# Required env vars: TIER, CERT_DOMAIN, AWS_REGION, COGNITO_CLIENT_ID,
#                    COGNITO_POOL_ID, TLS_CA_BUNDLE, TLS_CERT, TLS_KEY
# Optional:          NETWORK_CIDR (VPC CIDR for Dovecot login_trusted_networks)
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

# ── Step 2: Render sendmail.mc ────────────────────────────────
# The .mc template has __CERT_DOMAIN__ placeholders; replace with
# the actual domain and compile.
echo "[entrypoint] Rendering sendmail.mc..."
sed "s/__CERT_DOMAIN__/${CERT_DOMAIN}/g" \
  /etc/mail/sendmail.mc.template > /etc/mail/sendmail.mc

# ── Step 3: Cognito auth script (imap + smtp-out only) ────────
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

# ── Step 4: Dovecot SSL config (IMAP + SMTP-OUT) ─────────────
# Replaces: chef/cabal/templates/default/dovecot-10-ssl.conf.erb
if [ "$TIER" = "imap" ] || [ "$TIER" = "smtp-out" ]; then
  echo "[entrypoint] Building full certificate chain for Dovecot..."
  cat "/etc/pki/tls/certs/${CERT_DOMAIN}.crt" \
      "/etc/pki/tls/certs/${CERT_DOMAIN}.ca-bundle" \
      > "/etc/pki/tls/certs/${CERT_DOMAIN}.chain.crt"

  echo "[entrypoint] Generating dovecot SSL config..."
  # IMAP tier: NLB terminates TLS (993→143), so Dovecot must accept
  # plain-TCP connections from the NLB. Use "ssl = yes" (available but
  # not required) so auth is allowed on the forwarded plain connection.
  #
  # SMTP-OUT tier: NLB does TCP passthrough for submission (587/465),
  # so Dovecot handles TLS directly. Use "ssl = required".
  if [ "$TIER" = "imap" ]; then
    _ssl_mode="yes"
  else
    _ssl_mode="required"
  fi
  cat > /etc/dovecot/conf.d/10-ssl.conf <<SSLCONF
ssl = ${_ssl_mode}
ssl_cert = </etc/pki/tls/certs/${CERT_DOMAIN}.chain.crt
ssl_key = </etc/pki/tls/private/${CERT_DOMAIN}.key
ssl_min_protocol = TLSv1.2
SSLCONF

  # Set Dovecot login_trusted_networks: the source networks whose sessions
  # count as "secured" for auth. With disable_plaintext_auth = yes (Phase 4,
  # 10-auth.conf) only these may auth over the plain connection the imap NLB
  # forwards (993 -> TLS-terminated -> 143); anything reaching Dovecot from
  # elsewhere in the VPC must use real TLS. LOGIN_TRUSTED_NETWORKS is the NLB
  # public-subnet CIDRs (injected per-env by the task definition). It falls
  # back to NETWORK_CIDR (the whole VPC CIDR) so a missing/empty value fails
  # OPEN - no lockout of legitimate NLB-forwarded logins - rather than closed.
  # This also suppresses the noisy "Disconnected (no auth attempts)" logs from
  # the NLB's TCP health probes.
  _login_trusted="${LOGIN_TRUSTED_NETWORKS:-${NETWORK_CIDR:-}}"
  if [ -n "${_login_trusted}" ]; then
    echo "[entrypoint] Setting Dovecot login_trusted_networks = ${_login_trusted}"
    cat > /etc/dovecot/conf.d/05-login.conf <<LOGINCONF
login_trusted_networks = ${_login_trusted}
LOGINCONF
  fi
fi

# ── Step 5: Create OS users from Cognito (imap + smtp-out only) ─
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

# ── Step 6: Generate sendmail maps from DynamoDB ──────────────
# Replaces: chef/cabal/libraries/scan.rb + all ERB templates
echo "[entrypoint] Generating config from DynamoDB..."
/usr/local/bin/generate-config.sh

# ── Step 7: Compile sendmail config ───────────────────────────
echo "[entrypoint] Compiling sendmail configuration..."
make -C /etc/mail

# ── Step 8: Assemble aliases (IMAP only) ─────────────────────
# Static system aliases are baked into the image. Dynamic aliases
# (multi-user targets) are generated by generate-config.sh.
if [ "$TIER" = "imap" ]; then
  echo "[entrypoint] Assembling aliases..."
  cat /etc/aliases.static > /etc/aliases
  if [ -f /etc/aliases.dynamic ]; then
    echo "" >> /etc/aliases
    echo "# Dynamic aliases (generated from DynamoDB)" >> /etc/aliases
    cat /etc/aliases.dynamic >> /etc/aliases
  fi
  newaliases
fi

# ── Step 9: Dovecot master password (IMAP only) ──────────────
# Creates the master user for admin access to all mailboxes.
if [ "$TIER" = "imap" ]; then
  echo "[entrypoint] Setting dovecot master password..."
  htpasswd -b -c -s /etc/dovecot/master-users admin "${MASTER_PASSWORD}"
fi

# ── Step 10: Prepare rsyslog working directory ─────────────────
echo "[entrypoint] Preparing rsyslog..."
mkdir -p /var/lib/rsyslog

# ── Step 11: Pin IMAP_INTERNAL_HOST in /etc/hosts (smtp-in only) ──
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

# ── Step 12: Start services via supervisord ───────────────────
echo "[entrypoint] Starting services via supervisord..."
exec /usr/local/bin/supervisord -c /etc/supervisord.conf
