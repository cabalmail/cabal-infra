# Chef-to-Container Migration Plan

## Overview

This document describes the plan for replacing Chef Zero with Docker containers
running on AWS ECS (EC2 launch type). The migration preserves the existing
three-tier mail architecture (IMAP, SMTP-IN, SMTP-OUT) while replacing the
Chef-managed EC2 instances with container-based equivalents.

### Why ECS EC2 (not Fargate)

fail2ban requires `iptables` access, which means the `NET_ADMIN` Linux
capability. Fargate does not support `NET_ADMIN`. The plan is to start with
ECS on EC2 launch type — which still provides container orchestration, rolling
deploys, and service auto-scaling — and revisit Fargate in a later phase once
an alternative to fail2ban is in place.

### Migration Progression

```
Phase 1 ─ Dockerfiles & static config
         Build the three container images. Bake in packages and
         static files that never change at runtime.

Phase 2 ─ Entrypoint scripts & config generation
         Replace Chef recipes and Ruby libraries with shell scripts
         that query DynamoDB/Cognito at container start and render
         the sendmail/dovecot/dkim configs.

Phase 3 ─ Live-reconfiguration sidecar
         Replace the SSM→chef-solo reconfiguration path with a
         lightweight process that watches for address changes and
         rebuilds sendmail maps without restarting the container.

Phase 4 ─ Terraform: ASG modules → ECS modules
         New ECS cluster, services, task definitions, and ECR repos.
         Rewire NLB target groups. Preserve EFS, DynamoDB, Cognito,
         and all other existing resources.

Phase 5 ─ Lambda changes
         Replace SSM SendCommand with SNS publish. The sidecar
         subscribes via SQS.

Phase 6 ─ CI/CD
         Replace cookbook.yml with Docker build-and-push workflow.
         Tag images and reference them from Terraform.

Phase 7 ─ Parallel run & cutover
         Run containers alongside EC2/Chef. Validate mail flow for
         every address pattern. Cut over DNS. Decommission Chef.

Future  ─ Fargate migration
         Replace fail2ban with CloudWatch + Lambda IP-blocking.
         Switch ECS launch type from EC2 to Fargate.
```

---

## Phase 1 — Dockerfiles & Static Config

### Goal

Build three container images that have all packages installed and all static
configuration files in place. These images should be runnable (with the right
environment variables) but do NOT yet include runtime config generation.

### What moves into the Dockerfile

Everything that Chef installs or copies unconditionally — the "provision once"
work. Today this is spread across the recipes and `files/` directory:

| Chef source | Dockerfile equivalent |
|---|---|
| `package 'sendmail'`, `package 'sendmail-cf'` | `RUN yum install -y sendmail sendmail-cf` |
| `package 'dovecot'` | `RUN yum install -y dovecot` (IMAP image only) |
| `package 'opendkim'` | `RUN yum install -y opendkim` (SMTP-OUT image only) |
| `package 'fail2ban'` | `RUN yum install -y fail2ban` |
| `package 'sendmail-milter'` | `RUN yum install -y sendmail-milter` (SMTP-OUT image only) |
| `cookbook_file` for dovecot configs | `COPY` into `/etc/dovecot/conf.d/` |
| `cookbook_file` for PAM configs | `COPY` into `/etc/pam.d/` |
| `cookbook_file 'procmailrc'` | `COPY` into `/etc/` |
| `cookbook_file 'opendkim.conf'` | `COPY` into `/etc/` |
| `cookbook_file 'out-access'` | `COPY` into `/etc/mail/access` (SMTP-OUT image only) |
| `resources/port.rb` (firewalld) | Replaced by ECS security groups + `EXPOSE` |
| `service ... action [:start, :enable]` | Handled by `supervisord` in entrypoint |

### Static files that copy directly (no templating needed)

These 11 files from `chef/cabal/files/` go straight into the images:

```
# Dovecot (IMAP image only)
files/dovecot-10-auth.conf    → /etc/dovecot/conf.d/10-auth.conf
files/dovecot-10-mail.conf    → /etc/dovecot/conf.d/10-mail.conf
files/dovecot-15-mailboxes.conf → /etc/dovecot/conf.d/15-mailboxes.conf
files/dovecot-20-imap.conf    → /etc/dovecot/conf.d/20-imap.conf
files/dovecot-auth-master.conf → /etc/dovecot/conf.d/auth-master.conf.ext

# PAM (all images that need auth)
files/pam-dovecot             → /etc/pam.d/dovecot          (IMAP)
files/pam-sendmail            → /etc/pam.d/smtp             (SMTP-OUT)

# DKIM (SMTP-OUT only)
files/opendkim.conf           → /etc/opendkim.conf

# Procmail (IMAP only)
files/procmailrc              → /etc/procmailrc

# Sendmail access (SMTP-OUT only, static)
files/out-access              → /etc/mail/access
```

### Sendmail .mc files — baked into image, rendered at startup

The three `.mc.erb` templates have only one dynamic element: the TLS
certificate domain name (`node['sendmail']['cert']`). The m4 macro structure
is otherwise static. Strategy:

1. Copy the `.mc` template into the image with a placeholder:
   `__CERT_DOMAIN__`
2. At container start, `sed` replaces the placeholder with the
   `$CERT_DOMAIN` environment variable.
3. Run `make -C /etc/mail` to compile.

This avoids needing a full template engine for the `.mc` files.

### Proposed directory structure

```
docker/
├── imap/
│   ├── Dockerfile
│   ├── supervisord.conf
│   └── configs/
│       ├── dovecot/          # static dovecot configs
│       ├── pam/              # pam-dovecot
│       └── procmailrc
├── smtp-in/
│   ├── Dockerfile
│   ├── supervisord.conf
│   └── configs/
│       └── pam/              # (if needed)
├── smtp-out/
│   ├── Dockerfile
│   ├── supervisord.conf
│   └── configs/
│       ├── pam/              # pam-sendmail
│       └── opendkim.conf
├── shared/
│   ├── entrypoint.sh         # common startup logic
│   ├── generate-config.sh    # DynamoDB→sendmail map generator
│   ├── sync-users.sh         # Cognito→OS user sync
│   └── reconfigure.sh        # sidecar reconfiguration loop
└── templates/
    ├── imap-sendmail.mc       # .mc with __CERT_DOMAIN__ placeholders
    ├── in-sendmail.mc
    └── out-sendmail.mc
```

### Example: IMAP Dockerfile

```dockerfile
FROM amazonlinux:2

# System packages
RUN yum install -y \
      sendmail sendmail-cf \
      dovecot \
      fail2ban \
      procmail \
      awscli jq \
      python3 \
      supervisor \
    && yum clean all

# Static dovecot configuration
COPY configs/dovecot/10-auth.conf        /etc/dovecot/conf.d/10-auth.conf
COPY configs/dovecot/10-mail.conf        /etc/dovecot/conf.d/10-mail.conf
COPY configs/dovecot/15-mailboxes.conf   /etc/dovecot/conf.d/15-mailboxes.conf
COPY configs/dovecot/20-imap.conf        /etc/dovecot/conf.d/20-imap.conf
COPY configs/dovecot/auth-master.conf    /etc/dovecot/conf.d/auth-master.conf.ext

# PAM for dovecot (Cognito auth)
COPY configs/pam/dovecot                 /etc/pam.d/dovecot

# Procmail
COPY configs/procmailrc                  /etc/procmailrc

# Sendmail .mc template (placeholder for cert domain)
COPY templates/imap-sendmail.mc          /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh               /entrypoint.sh
COPY shared/generate-config.sh          /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh               /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh              /usr/local/bin/reconfigure.sh

# Supervisord config
COPY supervisord.conf                    /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 143 993 25

ENTRYPOINT ["/entrypoint.sh"]
```

---

## Phase 2 — Entrypoint Scripts & Config Generation

### Goal

Replace the Chef recipes and Ruby AWS libraries with shell scripts that run at
container startup. These scripts query DynamoDB and Cognito, render config
files, and start services.

### What the entrypoint replaces

| Chef component | Container equivalent |
|---|---|
| `libraries/scan.rb` (DynamoDBQuery) | `generate-config.sh` using `aws dynamodb scan` |
| `libraries/users.rb` (CognitoUsers) | `sync-users.sh` using `aws cognito-idp list-users` |
| `libraries/route53.rb` (Route53Record) | Moved to Lambda (see Phase 5) |
| `libraries/domain_helper.rb` | Inline in `generate-config.sh` |
| ERB template rendering | `awk`/`sed` or a small Python script |
| `service ... action [:start]` | `supervisord` |
| `execute 'make_sendmail'` | `make -C /etc/mail` in entrypoint |

### entrypoint.sh — startup sequence

```bash
#!/bin/bash
set -euo pipefail

TIER="${TIER}"  # "imap", "smtp-in", or "smtp-out" — from ECS task env

# ── Step 1: TLS certificates ──────────────────────────────────
# In ECS, certs come from Secrets Manager or SSM, injected as env
# vars or mounted as files via the task definition. Write them to
# the expected paths.
mkdir -p /etc/pki/tls/certs /etc/pki/tls/private /etc/opendkim/keys
echo "$TLS_CA_BUNDLE" > "/etc/pki/tls/certs/${CERT_DOMAIN}.ca-bundle"
echo "$TLS_CERT"      > "/etc/pki/tls/certs/${CERT_DOMAIN}.crt"
echo "$TLS_KEY"       > "/etc/pki/tls/private/${CERT_DOMAIN}.key"
chmod 600 "/etc/pki/tls/private/${CERT_DOMAIN}.key"

if [ "$TIER" = "smtp-out" ]; then
  echo "$DKIM_PRIVATE_KEY" > /etc/opendkim/keys/cabal
  chmod 600 /etc/opendkim/keys/cabal
  chown opendkim /etc/opendkim/keys/cabal
fi

# ── Step 2: Render sendmail.mc ────────────────────────────────
sed "s/__CERT_DOMAIN__/${CERT_DOMAIN}/g" \
  /etc/mail/sendmail.mc.template > /etc/mail/sendmail.mc

# ── Step 3: Cognito auth script ───────────────────────────────
cat > /usr/bin/cognito.bash <<COGNITO
#!/bin/bash
COGNITO_PASSWORD=\$(cat -)
COGNITO_USER="\${PAM_USER}"
aws cognito-idp initiate-auth \\
  --region ${AWS_REGION} \\
  --auth-flow USER_PASSWORD_AUTH \\
  --client-id ${COGNITO_CLIENT_ID} \\
  --auth-parameters "USERNAME=\${COGNITO_USER},PASSWORD=\"\${COGNITO_PASSWORD}\""
COGNITO
chmod 100 /usr/bin/cognito.bash

# ── Step 4: Create OS users from Cognito ──────────────────────
/usr/local/bin/sync-users.sh

# ── Step 5: Generate sendmail maps from DynamoDB ──────────────
/usr/local/bin/generate-config.sh

# ── Step 6: Compile sendmail config ───────────────────────────
make -C /etc/mail
newaliases

# ── Step 7: IMAP-specific: dovecot master password ────────────
if [ "$TIER" = "imap" ]; then
  yum install -y httpd-tools 2>/dev/null || true
  htpasswd -b -c -s /etc/dovecot/master-users admin "${MASTER_PASSWORD}"
  yum remove -y httpd-tools 2>/dev/null || true
fi

# ── Step 8: Start services via supervisord ────────────────────
exec /usr/bin/supervisord -c /etc/supervisord.conf
```

### sync-users.sh — replaces `_common_users.rb` + `libraries/users.rb`

```bash
#!/bin/bash
# Fetches users from Cognito and creates OS accounts.
# Replaces: chef/cabal/recipes/_common_users.rb
#           chef/cabal/libraries/users.rb
set -euo pipefail

aws cognito-idp list-users \
  --user-pool-id "$COGNITO_POOL_ID" \
  --region "$AWS_REGION" \
  --output json \
| jq -r '
  .Users[]
  | select(.UserStatus == "CONFIRMED")
  | select(.Attributes[]? | select(.Name == "custom:osid"))
  | {
      username: .Username,
      osid: (.Attributes[] | select(.Name == "custom:osid") | .Value)
    }
  | "\(.osid) \(.username)"
' | sort -n | while read -r osid username; do

  # Create group and user if they don't exist
  if ! getent group "$username" >/dev/null 2>&1; then
    groupadd -g "$osid" "$username"
  fi
  if ! getent passwd "$username" >/dev/null 2>&1; then
    useradd -u "$osid" -g "$osid" -m "$username"
  fi

  # Ensure home directory structure (idempotent)
  mkdir -p "/home/${username}/Maildir" "/home/${username}/.procmail"
  cp -n /etc/procmailrc "/home/${username}/.procmailrc" 2>/dev/null || true
  chown -R "${username}:${username}" "/home/${username}"
  chmod 700 "/home/${username}" "/home/${username}/Maildir"
  chmod 755 "/home/${username}/.procmail"
done
```

### generate-config.sh — replaces `libraries/scan.rb` + all ERB templates

This is the largest script. It replaces the DynamoDB scan, the domain data
structure construction, and all 10 address-dependent templates.

```bash
#!/bin/bash
# Queries DynamoDB cabal-addresses table and generates all sendmail
# map files, DKIM tables, and aliases.
#
# Replaces: chef/cabal/libraries/scan.rb
#           chef/cabal/libraries/domain_helper.rb
#           chef/cabal/templates/*.erb (address-dependent ones)
set -euo pipefail

TIER="${TIER}"
IMAP_HOST="imap.${CERT_DOMAIN}"

# ── Fetch address data from DynamoDB ──────────────────────────
ITEMS=$(aws dynamodb scan \
  --table-name cabal-addresses \
  --region "$AWS_REGION" \
  --output json)

# ── Use Python to parse and generate all config files ─────────
# Python is already on amazonlinux:2 and handles the nested
# domain/subdomain/address structure more cleanly than bash+jq.

python3 - "$TIER" "$IMAP_HOST" <<'PYEOF'
import json, sys, os

tier = sys.argv[1]
imap_host = sys.argv[2]
items_json = os.environ.get("ITEMS", "{}")
items = json.loads(items_json).get("Items", [])

# ── Build domain tree (mirrors Chef's DynamoDB scan logic) ────
# This reconstructs the exact data structure that Chef recipes
# build in _imap_sendmail.rb, _smtp-common_sendmail.rb, etc.
domains = {}
for item in items:
    # DynamoDB JSON uses typed wrappers; unwrap them
    tld = item.get("tld", {}).get("S", "")
    zone_id = item.get("zone-id", {}).get("S", "")
    username = item.get("username", {}).get("S", "")
    user = item.get("user", {}).get("S", "")
    subdomain = item.get("subdomain", {}).get("S", "") if "subdomain" in item else None
    private_key = item.get("private_key", {}).get("S", "") if "private_key" in item else None

    if tld not in domains:
        domains[tld] = {
            "zone-id": zone_id,
            "addresses": {},
            "subdomains": {},
        }
        if private_key:
            domains[tld]["private_key"] = private_key

    if subdomain:
        if subdomain not in domains[tld]["subdomains"]:
            domains[tld]["subdomains"][subdomain] = {
                "addresses": {},
                "action": "nothing",
            }
        targets = user.split("/")
        domains[tld]["subdomains"][subdomain]["addresses"][username] = targets
    else:
        domains[tld]["addresses"][username] = user


# ── Generator functions (one per template) ────────────────────

def gen_relay_domains():
    """Replaces relay-domains.erb — used by IMAP and SMTP-IN."""
    lines = []
    for tld in sorted(domains):
        lines.append(tld)
        for subd in sorted(domains[tld]["subdomains"]):
            lines.append(f"{subd}.{tld}")
    return "\n".join(lines) + "\n"


def gen_masq_domains():
    """Replaces masq-domains.erb — used by SMTP-IN and SMTP-OUT."""
    lines = []
    for tld in sorted(domains):
        lines.append(tld)
        for subd in sorted(domains[tld]["subdomains"]):
            lines.append(f"{subd}.{tld}")
    return "\n".join(lines) + "\n"


def gen_virtusertable():
    """Replaces virtusertable.erb — used by IMAP and SMTP-IN."""
    lines = []
    for tld in sorted(domains):
        d = domains[tld]
        for addr in sorted(d["addresses"]):
            lines.append(f"{addr}@{tld}\t{d['addresses'][addr]}")
        for subd in sorted(d["subdomains"]):
            sd = d["subdomains"][subd]
            for addr in sorted(sd["addresses"]):
                targets = sd["addresses"][addr]
                if isinstance(targets, list) and len(targets) > 1:
                    lines.append(f"{addr}@{subd}.{tld}\t{'_'.join(sorted(targets))}")
                else:
                    t = targets[0] if isinstance(targets, list) else targets
                    lines.append(f"{addr}@{subd}.{tld}\t{t}")
    return "\n".join(lines) + "\n"


def gen_mailertable():
    """Replaces mailertable.erb — used by SMTP-IN and SMTP-OUT."""
    lines = []
    for tld in sorted(domains):
        lines.append(f".{tld}\tsmtp:[{imap_host}]")
        lines.append(f"{tld}\tsmtp:[{imap_host}]")
    return "\n".join(lines) + "\n"


def gen_aliases():
    """Replaces aliases.erb — system aliases + multi-user targets.
    Mirrors DomainHelper.users() which finds array-valued addresses
    and creates combined aliases like user1_user2: user1, user2."""
    combined = {}
    for tld in domains:
        for subd in domains[tld].get("subdomains", {}):
            addrs = domains[tld]["subdomains"][subd]["addresses"]
            for addr in addrs:
                targets = addrs[addr]
                if isinstance(targets, list) and len(targets) > 1:
                    key = "_".join(sorted(targets))
                    combined[key] = sorted(targets)

    # The static system aliases are baked into the image as
    # /etc/aliases.static. We append the dynamic ones.
    lines = []
    for alias_name in sorted(combined):
        lines.append(f"{alias_name}: {', '.join(combined[alias_name])}")
    return "\n".join(lines) + "\n"


def gen_imap_access():
    """Replaces imap-access.erb."""
    lines = []
    for tld in sorted(domains):
        d = domains[tld]
        for addr in sorted(d["addresses"]):
            lines.append(f"To:{addr}@{tld}\tOK")
        for subd in sorted(d["subdomains"]):
            sd = d["subdomains"][subd]
            for addr in sorted(sd["addresses"]):
                lines.append(f"To:{addr}@{subd}.{tld}\tOK")
            lines.append(f"To:{subd}.{tld}\tREJECT")
        lines.append(f"To:{tld}\tREJECT")
    return "\n".join(lines) + "\n"


def gen_in_access():
    """Replaces in-access.erb."""
    lines = []
    for tld in sorted(domains):
        d = domains[tld]
        for addr in sorted(d["addresses"]):
            lines.append(f"To:{addr}@{tld}\tRELAY")
        for subd in sorted(d["subdomains"]):
            sd = d["subdomains"][subd]
            for addr in sorted(sd["addresses"]):
                lines.append(f"To:{addr}@{subd}.{tld}\tRELAY")
            lines.append(f"To:{subd}.{tld}\tREJECT")
        lines.append(f"To:{tld}\tREJECT")
    return "\n".join(lines) + "\n"


def gen_dkim_keytable():
    """Replaces dkim-keytable.erb."""
    lines = []
    for tld in sorted(domains):
        for subd in sorted(domains[tld]["subdomains"]):
            lines.append(
                f"cabal._domainkey.{subd}.{tld} "
                f"{subd}.{tld}:cabal:/etc/opendkim/keys/cabal"
            )
    return "\n".join(lines) + "\n"


def gen_dkim_signingtable():
    """Replaces dkim-signingtable.erb."""
    lines = []
    for tld in sorted(domains):
        for subd in sorted(domains[tld]["subdomains"]):
            lines.append(f"*@{subd}.{tld} cabal._domainkey.{subd}.{tld}")
    return "\n".join(lines) + "\n"


# ── Write files based on tier ─────────────────────────────────
def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    print(f"  Generated {path}")

if tier == "imap":
    write("/etc/mail/local-host-names", gen_relay_domains())
    write("/etc/mail/relay-domains",    gen_relay_domains())
    write("/etc/mail/access",           gen_imap_access())
    write("/etc/mail/virtusertable",    gen_virtusertable())
    write("/etc/aliases.dynamic",       gen_aliases())

elif tier == "smtp-in":
    write("/etc/mail/masq-domains",     gen_masq_domains())
    write("/etc/mail/access",           gen_in_access())
    write("/etc/mail/relay-domains",    gen_relay_domains())
    write("/etc/mail/mailertable",      gen_mailertable())
    write("/etc/mail/virtusertable",    gen_virtusertable())

elif tier == "smtp-out":
    write("/etc/mail/masq-domains",     gen_masq_domains())
    write("/etc/mail/mailertable",      gen_mailertable())
    write("/etc/opendkim/KeyTable",     gen_dkim_keytable())
    write("/etc/opendkim/SigningTable",  gen_dkim_signingtable())
    write("/etc/opendkim/TrustedHosts", "0.0.0.0/0\n")

PYEOF
```

### Environment variables (set via ECS task definition)

These replace `node.json` attributes and the Terraform `userdata` template
variables:

| Variable | Source | Replaces |
|---|---|---|
| `TIER` | Task definition | `run_list` recipe selector |
| `CERT_DOMAIN` | Task definition | `node['sendmail']['cert']` |
| `AWS_REGION` | Task definition | `node['cognito']['region']` / `node['ec2']['region']` |
| `COGNITO_CLIENT_ID` | Task definition | `node['cognito']['client_id']` |
| `COGNITO_POOL_ID` | Task definition | `node['cognito']['pool_id']` |
| `NETWORK_CIDR` | Task definition | `node['network']['cidr']` |
| `MASTER_PASSWORD` | Secrets Manager | `master_password` in userdata |
| `TLS_CA_BUNDLE` | Secrets Manager | SSM `/cabal/control_domain_chain_cert` |
| `TLS_CERT` | Secrets Manager | SSM `/cabal/control_domain_ssl_cert` |
| `TLS_KEY` | Secrets Manager | SSM `/cabal/control_domain_ssl_key` |
| `DKIM_PRIVATE_KEY` | Secrets Manager | SSM `/cabal/dkim_private_key` |

### Process management — supervisord

Each container runs multiple daemons. A minimal `supervisord.conf` for IMAP:

```ini
[supervisord]
nodaemon=true
logfile=/var/log/supervisord.log

[program:sendmail]
command=/usr/sbin/sendmail -bd -q15m
autorestart=true
priority=10

[program:dovecot]
command=/usr/sbin/dovecot -F
autorestart=true
priority=20

[program:fail2ban]
command=/usr/bin/fail2ban-server -xf
autorestart=true
priority=30

[program:reconfigure]
command=/usr/local/bin/reconfigure.sh
autorestart=true
priority=40
```

---

## Phase 3 — Live-Reconfiguration Sidecar

### Goal

Enable on-the-fly address changes without restarting or replacing containers.
This replaces the SSM SendCommand → chef-solo reconfiguration path that is
currently triggered by the `new` and `revoke` Lambdas when addresses are
created or deleted.

**Important distinction**: There are two separate reconfiguration concerns:

1. **Address changes** (common — ~1000 addresses, changed often): The `new`
   and `revoke` Lambdas write to the `cabal-addresses` DynamoDB table, then
   trigger chef-solo via SSM. Only sendmail maps need to be regenerated.
2. **User changes** (rare — ~4 users, changed infrequently): The
   `assign_osid` Lambda runs as a Cognito post-confirmation trigger and
   assigns a stable OS UID/GID so that file ownership is consistent across
   EFS. This requires creating OS accounts, which is done at container
   startup and does not need to happen on every address change.

The sidecar in this phase handles only address changes (concern 1). User
sync runs at container startup (Phase 2) and on the rare occasion a new
user is created, it is handled separately (see Phase 5).

### Current address reconfiguration flow (to be replaced)

```
POST /new or DELETE /revoke (API Gateway)
  → new / revoke Lambda
    → DynamoDB write (cabal-addresses)
    → kickOffChef() → SSM SendCommand (cabal_chef_document)
      → chef-solo on every EC2 instance
        → Full recipe re-execution (overkill: re-syncs users,
          regenerates all configs, restarts all services)
```

### New address reconfiguration flow

```
POST /new or DELETE /revoke (API Gateway)
  → new / revoke Lambda
    → DynamoDB write (cabal-addresses)
    → SNS publish to "cabal-address-changed" topic
      → SQS queue (one per service tier)
        → reconfigure.sh (running in each container)
          → DynamoDB scan → regenerate maps → makemap → HUP sendmail
```

### reconfigure.sh — the sidecar loop

This runs as a supervised process inside each container. It's the equivalent
of a chef-solo run, but faster and more targeted:

```bash
#!/bin/bash
# Watches for configuration change signals via SQS and regenerates
# sendmail maps. Sendmail reads .db files on HUP without needing a
# full restart.
#
# Replaces: SSM SendCommand → chef-solo full run
set -euo pipefail

QUEUE_URL="${SQS_QUEUE_URL}"

echo "[reconfigure] Starting config watch loop (queue: $QUEUE_URL)"

while true; do
  # Long-poll SQS (20s wait — free, no busy-loop)
  MSG=$(aws sqs receive-message \
    --queue-url "$QUEUE_URL" \
    --wait-time-seconds 20 \
    --max-number-of-messages 1 \
    --region "$AWS_REGION" \
    2>/dev/null || echo "{}")

  RECEIPT=$(echo "$MSG" | jq -r '.Messages[0].ReceiptHandle // empty')

  if [ -n "$RECEIPT" ]; then
    echo "[reconfigure] Change detected, regenerating configs..."

    # Re-run the same config generation used at startup
    /usr/local/bin/generate-config.sh

    # Rebuild sendmail hash databases
    makemap hash /etc/mail/access      < /etc/mail/access
    makemap hash /etc/mail/virtusertable < /etc/mail/virtusertable
    makemap hash /etc/mail/mailertable < /etc/mail/mailertable
    newaliases

    # Signal sendmail to re-read maps (no restart needed)
    pkill -HUP sendmail || true

    # For SMTP-OUT, also reload DKIM tables
    if [ "$TIER" = "smtp-out" ]; then
      pkill -HUP opendkim || true
    fi

    # Note: user sync is NOT needed here. Address changes do not
    # affect OS users. User creation is rare and handled separately
    # (see Phase 5).

    # Delete the message from the queue
    aws sqs delete-message \
      --queue-url "$QUEUE_URL" \
      --receipt-handle "$RECEIPT" \
      --region "$AWS_REGION"

    echo "[reconfigure] Done."
  fi
done
```

### Key design points

- **`makemap hash` + `HUP` is all that's needed for address changes.**
  Sendmail re-reads `.db` map files on SIGHUP. The `.mc` → `.cf` compilation
  is only needed when the sendmail macro config changes (adding features,
  changing TLS paths), which is a deploy-time concern, not a runtime one.

- **SQS long-polling costs nothing.** 20-second long-poll means near-zero API
  calls when idle, and sub-second response when a message arrives.

- **Multiple messages are collapsed.** If several addresses are created in
  quick succession, the sidecar drains one message, does one full regeneration
  (which picks up all changes from DynamoDB), then drains the rest as no-ops.

- **Fallback: periodic poll.** As a safety net, the sidecar can also do a
  time-based regeneration every N minutes, ensuring eventual consistency even
  if a message is lost.

---

## Phase 4 — Terraform: ASG → ECS

### Goal

Replace the `modules/asg` Terraform module with a new `modules/ecs` module.
Create an ECS cluster, ECR repositories, and three ECS services (one per
tier). Rewire the existing NLB target groups.

### New Terraform resources

```
terraform/infra/modules/ecs/
├── main.tf              # ECS cluster, capacity provider
├── ecr.tf               # ECR repositories (3)
├── services.tf          # ECS services (3)
├── task-definitions.tf  # Task definitions (3)
├── iam.tf               # Task execution role, task role
├── sqs.tf               # SQS queues for reconfiguration (3)
├── sns.tf               # SNS topic for address change fan-out
├── security_group.tf    # Retained from ASG module
├── variables.tf
└── outputs.tf
```

### ECS cluster with EC2 capacity

Current production runs one `t2.small` per tier. All three containers can
share a single EC2 instance at baseline, with the ASG scaling out additional
instances only when ECS can't place tasks (e.g., if SMTP auto-scaling pushes
resource demand beyond what one instance can handle).

```hcl
resource "aws_ecs_cluster" "mail" {
  name = "cabal-mail"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# A single instance handles all three tiers at baseline. The ASG
# exists for self-healing (replace unhealthy instances) and to scale
# out if ECS needs more capacity for SMTP container scaling.
resource "aws_autoscaling_group" "ecs" {
  vpc_zone_identifier = var.private_subnets[*].id
  desired_capacity    = 1
  max_size            = 3   # room for SMTP scaling
  min_size            = 1   # always at least one instance

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}

resource "aws_launch_template" "ecs" {
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = "t3.small"   # 2 GiB RAM, burstable — fits 3 containers

  # Minimal userdata — just join the ECS cluster
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.mail.name}" >> /etc/ecs/ecs.config
  EOF
  )

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }
}

# Capacity provider lets ECS request more instances from the ASG
# when it can't place a task (e.g., SMTP scaling needs more memory).
resource "aws_ecs_capacity_provider" "ec2" {
  name = "cabal-ec2"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100
    }
  }
}
```

### Task definitions (one per tier)

Resource reservations are sized for the current workload. SMTP-OUT gets a
larger share because OpenDKIM adds meaningful overhead.

```hcl
resource "aws_ecs_task_definition" "imap" {
  family                   = "cabal-imap"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "imap"
    image     = "${aws_ecr_repository.imap.repository_url}:${var.image_tag}"
    essential = true

    # Soft limit (memoryReservation) for placement; hard limit (memory)
    # as a ceiling. Dovecot + sendmail + fail2ban sit well under 512 MiB.
    memoryReservation = 384
    memory            = 512

    portMappings = [
      { containerPort = 143, protocol = "tcp" },
      { containerPort = 993, protocol = "tcp" },
      { containerPort = 25,  protocol = "tcp" },
    ]

    environment = [
      { name = "TIER",              value = "imap" },
      { name = "CERT_DOMAIN",       value = var.control_domain },
      { name = "AWS_REGION",        value = var.region },
      { name = "COGNITO_CLIENT_ID", value = var.client_id },
      { name = "COGNITO_POOL_ID",   value = var.user_pool_id },
      { name = "NETWORK_CIDR",      value = var.cidr_block },
      { name = "SQS_QUEUE_URL",     value = aws_sqs_queue.imap.url },
    ]

    secrets = [
      { name = "MASTER_PASSWORD", valueFrom = "/cabal/master_password" },
      { name = "TLS_CA_BUNDLE",   valueFrom = "/cabal/control_domain_chain_cert" },
      { name = "TLS_CERT",        valueFrom = "/cabal/control_domain_ssl_cert" },
      { name = "TLS_KEY",         valueFrom = "/cabal/control_domain_ssl_key" },
    ]

    mountPoints = [{
      sourceVolume  = "mailstore"
      containerPath = "/home"
    }]

    linuxParameters = {
      capabilities = {
        add = ["NET_ADMIN"]  # Required for fail2ban/iptables
      }
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/cabal-imap"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "imap"
      }
    }
  }])

  volume {
    name = "mailstore"
    efs_volume_configuration {
      file_system_id = var.efs_id
      root_directory = "/"
    }
  }
}

resource "aws_ecs_task_definition" "smtp_out" {
  family                   = "cabal-smtp-out"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "smtp-out"
    image     = "${aws_ecr_repository.smtp_out.repository_url}:${var.image_tag}"
    essential = true

    # OpenDKIM pushes memory consumption higher than other tiers.
    memoryReservation = 448
    memory            = 640

    portMappings = [
      { containerPort = 25,  protocol = "tcp" },
      { containerPort = 465, protocol = "tcp" },
      { containerPort = 587, protocol = "tcp" },
    ]

    # ... environment, secrets, linuxParameters, logConfiguration
    # same pattern as IMAP (with TIER = "smtp-out", DKIM_PRIVATE_KEY
    # added to secrets, no EFS mount)
  }])
}

# SMTP-IN task definition follows the same pattern as SMTP-OUT
# but without OpenDKIM — memoryReservation = 384, memory = 512.
```

### SNS/SQS for reconfiguration fan-out

```hcl
resource "aws_sns_topic" "address_changed" {
  name = "cabal-address-changed"
}

resource "aws_sqs_queue" "imap" {
  name                       = "cabal-reconfig-imap"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
}

resource "aws_sqs_queue" "smtp_in" {
  name                       = "cabal-reconfig-smtp-in"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
}

resource "aws_sqs_queue" "smtp_out" {
  name                       = "cabal-reconfig-smtp-out"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
}

# Fan-out: one SNS message → three SQS queues
resource "aws_sns_topic_subscription" "imap" {
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.imap.arn
}
resource "aws_sns_topic_subscription" "smtp_in" {
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.smtp_in.arn
}
resource "aws_sns_topic_subscription" "smtp_out" {
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.smtp_out.arn
}
```

### IAM task role

The ECS task role needs the same permissions that the current EC2 instance
profile grants (see `terraform/infra/modules/asg/iam.tf`):

| Permission | Purpose |
|---|---|
| `dynamodb:Scan` on `cabal-addresses` | `generate-config.sh` reads address data |
| `cognito-idp:ListUsers` | `sync-users.sh` reads user list |
| `sqs:ReceiveMessage`, `sqs:DeleteMessage` | `reconfigure.sh` reads change notifications |
| `route53:ChangeResourceRecordSets` | Not needed — infra DNS moves to Terraform; per-address DNS stays in Lambda |
| `ssm:GetParameter` | Only if secrets are read at runtime vs. injected by ECS |

### ECS services and scaling

**IMAP**: Hard-capped at one container. Dovecot has concurrency issues
with shared Maildir over EFS, so there must never be more than one IMAP
task running. ECS health checks still replace an unhealthy container
automatically — the replacement starts after the old one stops.

**SMTP-IN / SMTP-OUT**: Scale based on CPU/memory pressure. OpenDKIM on
the SMTP-OUT tier is the most likely bottleneck.

```hcl
# ── IMAP: exactly one, replaced if unhealthy ──────────────────
resource "aws_ecs_service" "imap" {
  name            = "cabal-imap"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.imap.arn
  desired_count   = 1

  # No auto-scaling — hard cap at 1 (see deployment config below).
  deployment_maximum_percent         = 100  # no extra task during deploy
  deployment_minimum_healthy_percent = 0    # allow brief downtime on deploy

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.imap.id]
  }

  load_balancer {
    target_group_arn = var.imap_target_group_arn
    container_name   = "imap"
    container_port   = 143
  }
}

# ── SMTP-IN: scales out under load ────────────────────────────
resource "aws_ecs_service" "smtp_in" {
  name            = "cabal-smtp-in"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.smtp_in.arn
  desired_count   = 1

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.smtp_in.id]
  }

  load_balancer {
    target_group_arn = var.relay_target_group_arn
    container_name   = "smtp-in"
    container_port   = 25
  }
}

# ── SMTP-OUT: scales out under load ───────────────────────────
resource "aws_ecs_service" "smtp_out" {
  name            = "cabal-smtp-out"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.smtp_out.arn
  desired_count   = 1

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.smtp_out.id]
  }

  load_balancer {
    target_group_arn = var.submission_target_group_arn
    container_name   = "smtp-out"
    container_port   = 465
  }
  load_balancer {
    target_group_arn = var.starttls_target_group_arn
    container_name   = "smtp-out"
    container_port   = 587
  }
}

# ── Auto-scaling for SMTP tiers ───────────────────────────────
# When SMTP containers need more resources (especially SMTP-OUT
# with OpenDKIM), ECS auto-scaling adds containers. The capacity
# provider automatically adds EC2 instances if needed to place them.

resource "aws_appautoscaling_target" "smtp_in" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.mail.name}/${aws_ecs_service.smtp_in.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "smtp_in_cpu" {
  name               = "cabal-smtp-in-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.smtp_in.resource_id
  scalable_dimension = aws_appautoscaling_target.smtp_in.scalable_dimension
  service_namespace  = aws_appautoscaling_target.smtp_in.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

resource "aws_appautoscaling_target" "smtp_out" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.mail.name}/${aws_ecs_service.smtp_out.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "smtp_out_cpu" {
  name               = "cabal-smtp-out-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.smtp_out.resource_id
  scalable_dimension = aws_appautoscaling_target.smtp_out.scalable_dimension
  service_namespace  = aws_appautoscaling_target.smtp_out.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
```

**How unhealthy container replacement works**: ECS health checks (via
the NLB TCP health checks on each service port) detect unresponsive
containers. For SMTP tiers, ECS starts a replacement before stopping the
old one (`deployment_minimum_healthy_percent = 100`). For IMAP, the old
task must stop first (`deployment_maximum_percent = 100`) to ensure only
one IMAP container accesses EFS at a time.

**How instance scaling works**: At baseline, one EC2 instance runs all
three containers. If SMTP auto-scaling adds containers that don't fit on
the current instance, the ECS capacity provider asks the ASG to launch
another instance (up to `max_size = 3`). When the SMTP load subsides and
containers scale back in, the capacity provider terminates the idle
instance.

### NLB target group changes

The existing NLB target groups must be changed from `target_type = "instance"`
(the current implicit default) to `target_type = "ip"` to work with ECS
`awsvpc` networking. This is a **destructive change** — Terraform will destroy
and recreate the target groups. During the parallel-run phase (Phase 7), create
new target groups for ECS alongside the existing ones to avoid downtime.

---

## Phase 5 — Lambda Changes

### Goal

Replace SSM `SendCommand` with SNS publish in the address Lambdas. Handle
user creation separately. Remove the `cabal_chef_document` SSM document.

### Address Lambdas: `new` and `revoke`

These are the primary reconfiguration triggers — they fire every time an
address is created or deleted. In both `lambda/api/node/new/index.js` and
`lambda/api/node/revoke/index.js`, replace the `kickOffChef()` function:

```javascript
// CURRENT — delete this
const command = {
  DocumentName: 'cabal_chef_document',
  Targets: [{
    "Key": "tag:managed_by_terraform",
    "Values": ["y"]
  }]
};
ssm.sendCommand(command, callback);
```

Replace with:

```javascript
// NEW — publish to SNS topic (picked up by container sidecars)
const sns = new AWS.SNS();
const params = {
  TopicArn: process.env.ADDRESS_CHANGED_TOPIC_ARN,
  Message: JSON.stringify({
    event: "address_changed",
    timestamp: new Date().toISOString()
  })
};
sns.publish(params).promise();
```

### assign_osid Lambda (user creation — rare, separate concern)

The `assign_osid` Lambda (`lambda/counter/node/assign_osid/index.js`) runs
as a Cognito post-confirmation trigger when a new user signs up. It assigns
a stable OS UID/GID via the `cabal-counter` DynamoDB table and then calls
`kickOffChef()`.

User creation is rare (~4 users total, changed infrequently), and the
container sidecar is designed for address changes, not user provisioning.
Two options for handling the rare new-user case:

1. **Publish to a separate SNS topic** (`cabal-user-changed`), consumed by a
   separate, lower-priority handler in the container that runs `sync-users.sh`.
   This keeps the address and user paths cleanly separated.
2. **Trigger an ECS service update** (force new deployment). Since user
   creation is rare, the 2-5 minute deployment time is acceptable. The new
   containers pick up the user at startup via `sync-users.sh`. This is the
   simplest option and avoids adding user-sync logic to the running container.

Option 2 is recommended for its simplicity. The `assign_osid` Lambda change:

```javascript
// Replace kickOffChef() with ECS service update
const ecs = new AWS.ECS();
const services = ['cabal-imap', 'cabal-smtp-in', 'cabal-smtp-out'];
for (const service of services) {
  await ecs.updateService({
    cluster: process.env.ECS_CLUSTER_NAME,
    service: service,
    forceNewDeployment: true
  }).promise();
}
```

### Route53 DNS registration

There are two distinct categories of DNS records:

1. **Infrastructure records** (e.g., `imap.<control_domain>` A record):
   Created once, points to the NLB. The IMAP Chef recipe (`_imap_dns.rb`)
   currently creates this using the instance IP. With ECS, this should move
   to Terraform as an `aws_route53_record` pointing to the NLB DNS name,
   since IMAP traffic already goes through the NLB.

2. **Per-address records** (MX, SPF, DMARC, DKIM for each mail address):
   Created and deleted by the `new` and `revoke` Lambdas respectively.
   These stay in Lambda — there is no reason to manage them in Terraform,
   and doing so would require a Terraform run for every address change.

---

## Phase 6 — CI/CD

### Goal

Replace `cookbook.yml` with a Docker image build-and-push workflow. Reference
image tags in Terraform.

### New workflow: docker-build.yml

Replaces `.github/workflows/cookbook.yml`:

```yaml
name: Build and Push Container Images

on:
  push:
    paths:
      - 'docker/**'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        tier: [imap, smtp-in, smtp-out]
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr

      - name: Build and push
        run: |
          IMAGE="${{ steps.ecr.outputs.registry }}/cabal-${{ matrix.tier }}"
          TAG="${{ github.sha }}"
          docker build \
            -f docker/${{ matrix.tier }}/Dockerfile \
            -t ${IMAGE}:${TAG} \
            -t ${IMAGE}:latest \
            docker/
          docker push ${IMAGE}:${TAG}
          docker push ${IMAGE}:latest
```

### Terraform integration

Add `image_tag` variable to the ECS module. The CI pipeline passes the git
SHA as the tag, and Terraform updates the task definition to reference it:

```hcl
variable "image_tag" {
  description = "Docker image tag (git SHA)"
  type        = string
  default     = "latest"
}
```

### Deployment flow

```
Push to docker/ → docker-build.yml builds 3 images → pushes to ECR
                → terraform.yml runs → updates task definition image tag
                → ECS rolling deployment replaces containers
```

This replaces the current flow:
```
Push to chef/ → cookbook.yml tars chef/ → uploads to S3
             → (manual) instance refresh triggers Chef re-run
```

---

## Phase 7 — Parallel Run & Cutover

### Goal

Run containers alongside EC2/Chef in parallel, validate mail delivery for
every address pattern, then cut over.

### Step 1: Deploy ECS alongside existing ASGs

- Create the ECS cluster and services with `desired_count = 1` each.
- Give them separate NLB target groups (not the production ones).
- Both systems read from the same DynamoDB table and Cognito pool.

### Step 2: Validate with test addresses

For each tier, verify:

| Test | What it validates |
|---|---|
| Send mail to `testaddr@domain.tld` (no subdomain) | SMTP-IN relay → IMAP delivery, virtusertable |
| Send mail to `testaddr@sub.domain.tld` | Subdomain routing, relay-domains |
| Send mail to multi-target alias | aliases file, combined user routing |
| Send from container via SMTP-OUT | DKIM signing, masq-domains, outbound relay |
| IMAP login with Cognito credentials | PAM auth, dovecot, cognito.bash |
| IMAP login with master user (`user*admin`) | Master user auth, dovecot master-users |
| Create new address, verify it works within 60s | Sidecar reconfiguration, SQS delivery |
| Create new Cognito user, verify OS account appears | sync-users.sh, user creation |
| Send to deleted/rejected address | access db REJECT rules |
| Verify fail2ban blocks after N failed logins | fail2ban + NET_ADMIN capability |

### Step 3: Switch NLB target groups

Once all tests pass:

1. Update Terraform to point NLB target groups at ECS services.
2. Apply. NLB health checks will verify the containers are responding.
3. Monitor for 24-48 hours.
4. Scale down the EC2 ASGs to 0.
5. After a further observation period, remove the ASG module from Terraform.

### Step 4: Clean up

- Remove `chef/` directory.
- Remove `cookbook.yml` workflow.
- Remove the `cabal_chef_document` SSM document.
- Remove Chef-related IAM permissions from ASG instance profile.
- Remove the S3 artifact (`cabal.tar.gz`) upload.

---

## Future — Fargate Migration

Once the ECS EC2 setup is stable, migrate to Fargate to eliminate EC2 instance
management entirely.

### Prerequisites

Replace fail2ban with a CloudWatch + Lambda solution:

1. Container logs go to CloudWatch (already configured via `awslogs` driver).
2. A CloudWatch metric filter matches auth-failure patterns in sendmail/dovecot
   logs.
3. A CloudWatch alarm triggers a Lambda when failure count exceeds threshold.
4. The Lambda adds the offending IP to a VPC Network ACL deny rule.
5. A scheduled Lambda cleans up expired blocks after a cooldown period.

### Fargate task definition changes

```hcl
resource "aws_ecs_task_definition" "imap" {
  # Change these:
  requires_compatibilities = ["FARGATE"]  # was ["EC2"]
  cpu                      = 512
  memory                   = 1024

  container_definitions = jsonencode([{
    # Remove this block:
    # linuxParameters = {
    #   capabilities = { add = ["NET_ADMIN"] }
    # }
    # ... rest stays the same
  }])
}
```

### Cost comparison

| Component | EC2 launch type | Fargate |
|---|---|---|
| Compute | EC2 instances (you manage capacity) | Per-task pricing (no idle capacity) |
| fail2ban | Free (runs in container) | Replaced by CloudWatch+Lambda (~$5-10/mo) |
| Management | ASG + capacity provider | Fully managed |

Fargate is likely cheaper at low scale (fewer than ~3 instances) because there
is no idle capacity. At higher scale, EC2 with reserved instances may be
cheaper.

---

## Appendix A: File-by-File Migration Map

Every Chef file and its container-world equivalent:

### Recipes → Scripts/Dockerfile

| Chef recipe | Migrates to |
|---|---|
| `recipes/imap.rb` | `docker/imap/Dockerfile` + `entrypoint.sh` |
| `recipes/smtp-in.rb` | `docker/smtp-in/Dockerfile` + `entrypoint.sh` |
| `recipes/smtp-out.rb` | `docker/smtp-out/Dockerfile` + `entrypoint.sh` |
| `recipes/_common.rb` | `Dockerfile` (fail2ban install) + `entrypoint.sh` (cognito.bash) |
| `recipes/_common_users.rb` | `sync-users.sh` |
| `recipes/_imap_dovecot.rb` | `Dockerfile` COPY commands (static configs) |
| `recipes/_imap_sendmail.rb` | `generate-config.sh` (DynamoDB scan + file gen) |
| `recipes/_imap_dns.rb` | Terraform `aws_route53_record` (infra A record for NLB) |
| `recipes/_smtp-common_sendmail.rb` | `generate-config.sh` |
| `recipes/_smtp-in_sendmail.rb` | `generate-config.sh` |
| `recipes/_smtp-out_sendmail.rb` | `Dockerfile` + `entrypoint.sh` |
| `recipes/_smtp-out_dkim.rb` | `generate-config.sh` (DKIM tables) + `Dockerfile` |

### Libraries → Scripts

| Chef library | Migrates to |
|---|---|
| `libraries/scan.rb` | `aws dynamodb scan` in `generate-config.sh` |
| `libraries/users.rb` | `aws cognito-idp list-users` in `sync-users.sh` |
| `libraries/route53.rb` | Terraform `aws_route53_record` (infra A record only) |
| `libraries/domain_helper.rb` | Python logic in `generate-config.sh` |

### Templates → Script output

| Chef template | Generated by |
|---|---|
| `templates/imap-sendmail.mc.erb` | `sed` placeholder replacement in `entrypoint.sh` |
| `templates/in-sendmail.mc.erb` | `sed` placeholder replacement in `entrypoint.sh` |
| `templates/out-sendmail.mc.erb` | `sed` placeholder replacement in `entrypoint.sh` |
| `templates/virtusertable.erb` | `gen_virtusertable()` in `generate-config.sh` |
| `templates/aliases.erb` | `gen_aliases()` in `generate-config.sh` |
| `templates/relay-domains.erb` | `gen_relay_domains()` in `generate-config.sh` |
| `templates/masq-domains.erb` | `gen_masq_domains()` in `generate-config.sh` |
| `templates/mailertable.erb` | `gen_mailertable()` in `generate-config.sh` |
| `templates/in-access.erb` | `gen_in_access()` in `generate-config.sh` |
| `templates/imap-access.erb` | `gen_imap_access()` in `generate-config.sh` |
| `templates/dkim-keytable.erb` | `gen_dkim_keytable()` in `generate-config.sh` |
| `templates/dkim-signingtable.erb` | `gen_dkim_signingtable()` in `generate-config.sh` |
| `templates/dovecot-10-ssl.conf.erb` | `sed` placeholder replacement in `entrypoint.sh` |
| `templates/cognito.bash.erb` | Inline `cat` in `entrypoint.sh` |

### Static files → COPY in Dockerfile

| Chef file | Dockerfile COPY target |
|---|---|
| `files/dovecot-10-auth.conf` | `/etc/dovecot/conf.d/10-auth.conf` |
| `files/dovecot-10-mail.conf` | `/etc/dovecot/conf.d/10-mail.conf` |
| `files/dovecot-15-mailboxes.conf` | `/etc/dovecot/conf.d/15-mailboxes.conf` |
| `files/dovecot-20-imap.conf` | `/etc/dovecot/conf.d/20-imap.conf` |
| `files/dovecot-auth-master.conf` | `/etc/dovecot/conf.d/auth-master.conf.ext` |
| `files/pam-dovecot` | `/etc/pam.d/dovecot` |
| `files/pam-sendmail` | `/etc/pam.d/smtp` |
| `files/opendkim.conf` | `/etc/opendkim.conf` |
| `files/procmailrc` | `/etc/procmailrc` |
| `files/out-access` | `/etc/mail/access` (SMTP-OUT only) |

### Terraform changes

| Current resource | New resource |
|---|---|
| `modules/asg/main.tf` (launch template + ASG) | `modules/ecs/main.tf` (ECS cluster + capacity provider) |
| `modules/asg/iam.tf` (instance profile) | `modules/ecs/iam.tf` (task role + execution role) |
| `modules/asg/security_group.tf` | `modules/ecs/security_group.tf` (unchanged logic) |
| `modules/asg/templates/userdata` (Chef bootstrap) | `modules/ecs/main.tf` (2-line ECS agent config) |
| (none) | `modules/ecs/ecr.tf` (3 ECR repositories) |
| (none) | `modules/ecs/sns.tf` + `sqs.tf` (reconfiguration fan-out) |
| (none) | `modules/ecs/services.tf` (3 ECS services) |
| (none) | `modules/ecs/task-definitions.tf` (3 task definitions) |

### CI/CD changes

| Current workflow | New workflow |
|---|---|
| `.github/workflows/cookbook.yml` | `.github/workflows/docker-build.yml` |
| Tars `chef/` → uploads to S3 | Builds 3 Docker images → pushes to ECR |
