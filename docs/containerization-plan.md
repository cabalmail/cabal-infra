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
| `ROUTE53_ZONE_ID` | Task definition | `node['route53']['zone_id']` |
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
This replaces the current `assign_osid` Lambda → SSM SendCommand → chef-solo
reconfiguration path.

### Current reconfiguration flow (to be replaced)

```
assign_osid Lambda
  → SSM SendCommand (cabal_chef_document)
    → Runs chef-solo on every EC2 instance
      → Full recipe re-execution: DynamoDB scan, template render,
        service restart
```

### New reconfiguration flow

```
Address-change Lambda (new/update/delete)
  → SNS publish to "cabal-config-changed" topic
    → SQS queue (one per service)
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

    # Sync users (new Cognito users may have been added)
    /usr/local/bin/sync-users.sh

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
├── sns.tf               # SNS topic for config change fan-out
├── security_group.tf    # Retained from ASG module
├── variables.tf
└── outputs.tf
```

### ECS cluster with EC2 capacity

```hcl
resource "aws_ecs_cluster" "mail" {
  name = "cabal-mail"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# EC2 capacity provider — manages the underlying instances
resource "aws_autoscaling_group" "ecs" {
  # Similar to current ASG but using ECS-optimized AMI
  # and ECS agent userdata instead of Chef
  vpc_zone_identifier = var.private_subnets[*].id
  desired_capacity    = var.capacity.desired
  max_size            = var.capacity.max
  min_size            = var.capacity.min

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }
}

resource "aws_launch_template" "ecs" {
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = var.instance_type

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
    memory    = 512

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
      { name = "ROUTE53_ZONE_ID",   value = var.private_zone_id },
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
```

### SNS/SQS for reconfiguration fan-out

```hcl
resource "aws_sns_topic" "config_changed" {
  name = "cabal-config-changed"
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
  topic_arn = aws_sns_topic.config_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.imap.arn
}
resource "aws_sns_topic_subscription" "smtp_in" {
  topic_arn = aws_sns_topic.config_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.smtp_in.arn
}
resource "aws_sns_topic_subscription" "smtp_out" {
  topic_arn = aws_sns_topic.config_changed.arn
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
| `route53:ChangeResourceRecordSets` | DNS registration (IMAP only, or moved to Lambda) |
| `ssm:GetParameter` | Only if secrets are read at runtime vs. injected by ECS |

### NLB target group changes

The existing NLB target groups currently point to EC2 instance IDs registered
by the ASG. With ECS, they point to IP targets registered by the ECS service's
`awsvpc` networking:

```hcl
resource "aws_ecs_service" "imap" {
  name            = "cabal-imap"
  cluster         = aws_ecs_cluster.mail.id
  task_definition = aws_ecs_task_definition.imap.arn
  desired_count   = var.imap_scale.desired

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 100
  }

  network_configuration {
    subnets         = var.private_subnets[*].id
    security_groups = [aws_security_group.imap.id]
  }

  # Wire to existing NLB target groups
  load_balancer {
    target_group_arn = var.imap_target_group_143
    container_name   = "imap"
    container_port   = 143
  }
  load_balancer {
    target_group_arn = var.imap_target_group_993
    container_name   = "imap"
    container_port   = 993
  }
}
```

The NLB target groups must be changed from `target_type = "instance"` to
`target_type = "ip"` to work with `awsvpc` mode.

---

## Phase 5 — Lambda Changes

### Goal

Replace SSM `SendCommand` with SNS publish. Remove the `cabal_chef_document`
SSM document.

### assign_osid Lambda change

In `lambda/counter/node/assign_osid/index.js`, the `kickOffChef()` function
currently does:

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
// NEW — publish to SNS topic
const sns = new AWS.SNS();
const params = {
  TopicArn: process.env.CONFIG_CHANGED_TOPIC_ARN,
  Message: JSON.stringify({
    event: "user_created",
    timestamp: new Date().toISOString()
  })
};
sns.publish(params).promise();
```

### new_address Lambda

The `new_address` Lambda (currently incomplete) should also publish to the same
SNS topic after writing to DynamoDB. Any Lambda that modifies the
`cabal-addresses` table or the Cognito user pool should publish a change
notification.

### Route53 DNS registration

The IMAP Chef recipe (`_imap_dns.rb`) creates a Route53 A record for
`imap.<control_domain>` using the instance's IP. In ECS with `awsvpc`, each
task gets its own ENI with a private IP. Two options:

1. **Move to Terraform** — create the A record as a Terraform resource
   pointing to the NLB DNS name (simpler, already load-balanced).
2. **Move to Lambda** — a small Lambda triggered by ECS task state changes
   updates the record (if direct-to-instance resolution is needed).

Option 1 is preferred since IMAP traffic already goes through the NLB.

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
| `recipes/_imap_dns.rb` | Terraform `aws_route53_record` resource (or Lambda) |
| `recipes/_smtp-common_sendmail.rb` | `generate-config.sh` |
| `recipes/_smtp-in_sendmail.rb` | `generate-config.sh` |
| `recipes/_smtp-out_sendmail.rb` | `Dockerfile` + `entrypoint.sh` |
| `recipes/_smtp-out_dkim.rb` | `generate-config.sh` (DKIM tables) + `Dockerfile` |

### Libraries → Scripts

| Chef library | Migrates to |
|---|---|
| `libraries/scan.rb` | `aws dynamodb scan` in `generate-config.sh` |
| `libraries/users.rb` | `aws cognito-idp list-users` in `sync-users.sh` |
| `libraries/route53.rb` | Terraform resource or Lambda |
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
