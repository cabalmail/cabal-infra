#!/bin/bash
# Queries DynamoDB cabal-addresses table and generates all sendmail
# map files, DKIM tables, and aliases.
#
# Replaces: chef/cabal/libraries/scan.rb
#           chef/cabal/libraries/domain_helper.rb
#           chef/cabal/templates/*.erb (address-dependent ones)
#
# Required env vars: TIER, CERT_DOMAIN, AWS_REGION
set -euo pipefail

IMAP_HOST="imap.${CERT_DOMAIN}"

# ── Fetch address data from DynamoDB ──────────────────────────
echo "[generate-config] Scanning DynamoDB cabal-addresses table..."
ITEMS=$(aws dynamodb scan \
  --table-name cabal-addresses \
  --region "$AWS_REGION" \
  --output json)

# ── Use Python to parse and generate all config files ─────────
# Python handles the nested domain/subdomain/address structure
# more cleanly than bash+jq.
echo "[generate-config] Generating config files for tier=$TIER..."

export ITEMS
python3 - "$TIER" "$IMAP_HOST" <<'PYEOF'
import json, sys, os

tier = sys.argv[1]
imap_host = sys.argv[2]
items_json = os.environ.get("ITEMS", "{}")
items = json.loads(items_json).get("Items", [])

# ── Build domain tree (mirrors Chef's DynamoDB scan logic) ────
# Reconstructs the exact data structure that Chef recipes build in
# _imap_sendmail.rb, _smtp-common_sendmail.rb, _smtp-out_dkim.rb.
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
    """Replaces aliases.erb — dynamic aliases for multi-user targets.
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

echo "[generate-config] Done."
