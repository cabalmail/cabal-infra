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

# IMAP_INTERNAL_HOST is a Cloud Map service discovery hostname
# (imap.cabal.internal) that resolves directly to the IMAP container's
# ENI IP.  The mailertable uses this so that sendmail connects to the
# IMAP container on port 25 without going through the NLB (whose
# port 25 listener routes to smtp-in, not imap).
IMAP_HOST="${IMAP_INTERNAL_HOST:-imap.${CERT_DOMAIN}}"

# ── Fetch address data from DynamoDB ──────────────────────────
# The AWS CLI v2 auto-paginates dynamodb scan, merging all Items
# across pages into a single response.  No manual loop needed.
# The scan output goes to a temp file so it can be read by Python
# without hitting Linux's ~2 MB arg+env size limit that the old
# export-to-env-var approach was subject to.
echo "[generate-config] Scanning DynamoDB cabal-addresses table..."
ITEMS_FILE=$(mktemp)
trap 'rm -f "$ITEMS_FILE"' EXIT
aws dynamodb scan \
  --table-name cabal-addresses \
  --consistent-read \
  --region "$AWS_REGION" \
  --output json > "$ITEMS_FILE"

# ── Use Python to parse and generate all config files ─────────
# Python handles the nested domain/subdomain/address structure
# more cleanly than bash+jq.
echo "[generate-config] Generating config files for tier=$TIER..."

python3 - "$TIER" "$IMAP_HOST" "$ITEMS_FILE" <<'PYEOF'
import json, os, sys

tier = sys.argv[1]
imap_host = sys.argv[2]
with open(sys.argv[3]) as f:
    items = json.load(f).get("Items", [])

# ── Build domain tree (mirrors Chef's DynamoDB scan logic) ────
# Reconstructs the exact data structure that Chef recipes build in
# _imap_sendmail.rb, _smtp-common_sendmail.rb, _smtp-out_dkim.rb.
domains = {}
for item in items:
    # DynamoDB JSON uses typed wrappers; unwrap them
    tld = item.get("tld", {}).get("S", "")
    username = item.get("username", {}).get("S", "")
    user = item.get("user", {}).get("S", "")
    subdomain = item.get("subdomain", {}).get("S", "") if "subdomain" in item else None

    # Skip rows whose username carries whitespace. Such a value is written
    # verbatim into virtusertable, where makemap rejects a leading space and
    # treats a tab as the key/value separator -- either wedges the map rebuild
    # for the whole tier and crash-loops the reconfigure sidecar. The API now
    # rejects these at creation (helper.validate_local_part), but a legacy row
    # or any other write path must not be able to freeze reconfiguration.
    if not username or any(c.isspace() for c in username):
        print(f"  WARNING: skipping address with invalid username "
              f"{username!r} (tld={tld!r}, subdomain={subdomain!r})",
              file=sys.stderr)
        continue

    if tld not in domains:
        domains[tld] = {
            "addresses": {},
            "subdomains": {},
        }

    if subdomain:
        if subdomain not in domains[tld]["subdomains"]:
            domains[tld]["subdomains"][subdomain] = {"addresses": {}}
        # Always a list, one entry per co-assigned user: `user` is the
        # slash-delimited multi-user attribute, and str.split never
        # returns fewer than one element.
        targets = user.split("/")
        domains[tld]["subdomains"][subdomain]["addresses"][username] = targets
    else:
        domains[tld]["addresses"][username] = user


# ── Generator functions (one per template) ────────────────────

def gen_domain_list():
    """Every hosted name, one per line: each tld followed by its subdomains.

    relay-domains, local-host-names and masq-domains all want exactly this
    list, so they share one generator."""
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
                if len(targets) > 1:
                    lines.append(f"{addr}@{subd}.{tld}\t{'_'.join(sorted(targets))}")
                else:
                    lines.append(f"{addr}@{subd}.{tld}\t{targets[0]}")
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
                if len(targets) > 1:
                    key = "_".join(sorted(targets))
                    combined[key] = sorted(targets)

    lines = []
    for alias_name in sorted(combined):
        lines.append(f"{alias_name}: {', '.join(combined[alias_name])}")
    return "\n".join(lines) + "\n"


def gen_access(known, unknown):
    """Access map: every provisioned address gets `known`, every bare domain
    and subdomain gets `unknown` (there is no apex or catch-all addressing).
    The two tiers differ only in which verbs they use."""
    lines = []
    for tld in sorted(domains):
        d = domains[tld]
        for addr in sorted(d["addresses"]):
            lines.append(f"To:{addr}@{tld}\t{known}")
        for subd in sorted(d["subdomains"]):
            sd = d["subdomains"][subd]
            for addr in sorted(sd["addresses"]):
                lines.append(f"To:{addr}@{subd}.{tld}\t{known}")
            lines.append(f"To:{subd}.{tld}\t{unknown}")
        lines.append(f"To:{tld}\t{unknown}")
    return "\n".join(lines) + "\n"


def gen_imap_access():
    """Replaces imap-access.erb."""
    return gen_access("OK", "TEMPFAIL")


def gen_in_access():
    """Replaces in-access.erb."""
    return gen_access("RELAY", "REJECT")


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
    # Atomic write: stage to a temp file in the same directory, fsync,
    # then os.replace (atomic on POSIX). A SIGHUP, restart, or a sendmail
    # makemap that lands mid-write never sees a partially written map.
    # Phase 5 of docs/0.10.x/container-runtime-hardening-plan.md.
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    print(f"  Generated {path}")

if tier == "imap":
    write("/etc/mail/local-host-names", gen_domain_list())
    write("/etc/mail/relay-domains",    gen_domain_list())
    write("/etc/mail/access",           gen_imap_access())
    write("/etc/mail/virtusertable",    gen_virtusertable())
    write("/etc/aliases.dynamic",       gen_aliases())

elif tier == "smtp-in":
    write("/etc/mail/masq-domains",     gen_domain_list())
    write("/etc/mail/access",           gen_in_access())
    write("/etc/mail/relay-domains",    gen_domain_list())
    write("/etc/mail/mailertable",      gen_mailertable())
    write("/etc/mail/virtusertable",    gen_virtusertable())

elif tier == "smtp-out":
    write("/etc/mail/masq-domains",     gen_domain_list())
    write("/etc/mail/mailertable",      gen_mailertable())
    write("/etc/opendkim/KeyTable",     gen_dkim_keytable())
    write("/etc/opendkim/SigningTable",  gen_dkim_signingtable())
    # Sign only mail handed over by the local sendmail via the loopback
    # milter socket (inet:8891@localhost). The previous 0.0.0.0/0 made
    # opendkim treat every source as internal, so any host that reached
    # the milter would get a signature for any From it could match in the
    # SigningTable. Loopback-only closes that: now both the network
    # position (here) and the From-domain match (SigningTable) must hold.
    # Phase 5 of docs/0.10.x/container-runtime-hardening-plan.md.
    write("/etc/opendkim/TrustedHosts", "127.0.0.1\n::1\nlocalhost\n")

PYEOF

# Sinkhole test fixture (smtp-out only).
#
# When SINKHOLE_ENABLED=true is injected into the smtp-out task by
# Terraform (var.sinkhole), append a mailertable entry that routes
# anything addressed to sinkhole.test (RFC 2606 reserved TLD - never
# resolves on the public internet) to the in-VPC Cloud Map name
# sinkhole.cabal.internal on port 25. The bracket-and-port syntax
# skips MX lookup; sendmail connects directly to whatever the private
# resolver returns.
#
# Regenerated on every reconfigure for free, so flipping var.sinkhole
# does not require a docker rebuild - only a task replacement that
# picks up the new env var. See
# docs/0.9.x/sinkhole-test-harness-plan.md.
# The imap tier joins smtp-out here as of user-mail-rules Phase 2b:
# rule forwards are submitted by cabal-forward-drain.sh on the imap
# container, so forward-to-sinkhole test traffic originates there. imap
# generates no mailertable otherwise (its FEATURE(mailertable) is
# optional-file), so the sinkhole entry is the whole file on that tier.
if { [ "$TIER" = "smtp-out" ] || [ "$TIER" = "imap" ]; } \
    && [ "${SINKHOLE_ENABLED:-false}" = "true" ]; then
  echo "[generate-config] Appending sinkhole.test mailertable entry"
  echo "sinkhole.test	smtp:[sinkhole.cabal.internal]:25" >> /etc/mail/mailertable
fi

echo "[generate-config] Done."
