#!/usr/bin/env python3
"""Backfill BIMI DNS records for address subdomains that predate BIMI publishing.

Since BIMI shipped, the `new` Lambda publishes a
`default._bimi.<subdomain>.<tld>` TXT record alongside the other per-address
records (MX/SPF/DKIM/DMARC). Subdomains created before that have every record
except the BIMI one. This script finds them and adds the missing record,
using the exact value the Lambda publishes today.

Designed to run in AWS CloudShell with ambient credentials (boto3 is
preinstalled there). Run it once per environment (dev/stage/prod CloudShell).

Configuration is read from the deployed `new` Lambda's environment
(DOMAINS: tld -> hosted zone id, CONTROL_DOMAIN), so the script cannot drift
from what production actually publishes and needs no arguments.

Selection logic, per distinct (subdomain, tld) in the `cabal-addresses` table:

- The subdomain's MX record must exist in the zone. A subdomain without its
  MX is not live (all addresses suspended, or a partially revoked leftover);
  suspended subdomains' contract is "DNS absent" and reinstate republishes
  the full set - including BIMI - so they need no backfill.
- The `default._bimi` TXT must be absent. An existing record is left alone
  (reported if its value differs from the canonical one, never overwritten).

Dry run by default: prints what would change and exits. Pass --apply to
write the records.

Example:

  ./scripts/backfill-bimi-records.py            # report only
  ./scripts/backfill-bimi-records.py --apply    # write missing records
"""

import argparse
import json
import sys

import boto3

LOG_TAG = "[backfill-bimi]"

# Mirrors the Lambda's records: helper.address_dns_records / new.create_dns_records.
TTL = 3600
# Route 53 caps a change batch at 1000 changes / 32000 value chars; stay well under.
CHANGE_BATCH_SIZE = 100


def log(msg):
    """Prints a tagged log line."""
    print(f"{LOG_TAG} {msg}")


def bimi_value(control_domain):
    """Canonical BIMI TXT value, exactly as the `new` Lambda publishes it."""
    return f'"v=BIMI1; l=https://www.{control_domain}/assets/bimi/cabalmail.svg"'


def load_lambda_config(lambda_client):
    """Reads DOMAINS and CONTROL_DOMAIN from the deployed `new` Lambda."""
    conf = lambda_client.get_function_configuration(FunctionName="new")
    env = conf["Environment"]["Variables"]
    return json.loads(env["DOMAINS"]), env["CONTROL_DOMAIN"]


def distinct_subdomains(table):
    """Scans cabal-addresses and returns the distinct (subdomain, tld) pairs."""
    pairs = set()
    scan_kwargs = {"ProjectionExpression": "subdomain, tld"}
    while True:
        response = table.scan(**scan_kwargs)
        for item in response.get("Items", []):
            pairs.add((item["subdomain"], item["tld"]))
        if "LastEvaluatedKey" not in response:
            break
        scan_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
    return sorted(pairs)


def zone_records(r53, zone_id):
    """Returns {(name, type): first record value} for every rrset in the zone.
    Names are normalized to lowercase without the trailing dot."""
    records = {}
    paginator = r53.get_paginator("list_resource_record_sets")
    for page in paginator.paginate(HostedZoneId=zone_id):
        for rrset in page["ResourceRecordSets"]:
            name = rrset["Name"].rstrip(".").lower()
            values = rrset.get("ResourceRecords", [])
            value = values[0]["Value"] if values else None
            records[(name, rrset["Type"])] = value
    return records


def plan_changes(pairs, domains, control_domain, r53):
    """Builds {zone_id: [missing BIMI record names]} for live subdomains."""
    zones = {}   # zone_id -> {(name, type): value}
    planned = {}  # zone_id -> [record names]
    for subdomain, tld in pairs:
        zone_id = domains.get(tld)
        if zone_id is None:
            log(f"WARN {subdomain}.{tld}: tld not in DOMAINS, skipping")
            continue
        if zone_id not in zones:
            zones[zone_id] = zone_records(r53, zone_id)
        records = zones[zone_id]
        apex = f"{subdomain}.{tld}".lower()
        bimi_name = f"default._bimi.{apex}"
        if (apex, "MX") not in records:
            log(f"skip {apex}: no MX record (not live; suspended or leftover)")
            continue
        if (bimi_name, "TXT") in records:
            existing = records[(bimi_name, "TXT")]
            if existing != bimi_value(control_domain):
                log(f"WARN {bimi_name}: TXT exists with unexpected value "
                    f"{existing!r}, leaving it alone")
            continue
        planned.setdefault(zone_id, []).append(bimi_name)
    return planned


def apply_changes(r53, zone_id, names, control_domain):
    """UPSERTs the BIMI TXT records for the given names, in batches."""
    for start in range(0, len(names), CHANGE_BATCH_SIZE):
        batch = names[start:start + CHANGE_BATCH_SIZE]
        r53.change_resource_record_sets(
            HostedZoneId=zone_id,
            ChangeBatch={"Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": name,
                    "Type": "TXT",
                    "TTL": TTL,
                    "ResourceRecords": [{"Value": bimi_value(control_domain)}],
                },
            } for name in batch]},
        )
        log(f"applied {len(batch)} records in zone {zone_id}")


def main():
    """Entry point."""
    parser = argparse.ArgumentParser(
        description="Backfill default._bimi TXT records for pre-BIMI subdomains")
    parser.add_argument("--apply", action="store_true",
                        help="write the missing records (default: dry run)")
    parser.add_argument("--tld", help="only consider subdomains on this mail domain")
    args = parser.parse_args()

    session = boto3.session.Session()
    domains, control_domain = load_lambda_config(session.client("lambda"))
    log(f"control domain: {control_domain}; mail domains: {', '.join(sorted(domains))}")

    table = session.resource("dynamodb").Table("cabal-addresses")
    pairs = distinct_subdomains(table)
    if args.tld:
        if args.tld not in domains:
            log(f"ERROR unknown --tld {args.tld!r}")
            return 1
        pairs = [(s, t) for s, t in pairs if t == args.tld]
    log(f"{len(pairs)} distinct subdomains in cabal-addresses")

    r53 = session.client("route53")
    planned = plan_changes(pairs, domains, control_domain, r53)
    total = sum(len(names) for names in planned.values())
    if total == 0:
        log("nothing to do: every live subdomain already has its BIMI record")
        return 0

    for zone_id, names in sorted(planned.items()):
        for name in names:
            log(f"missing: {name} (zone {zone_id})")
    if not args.apply:
        log(f"dry run: would add {total} records; re-run with --apply to write them")
        return 0

    for zone_id, names in sorted(planned.items()):
        apply_changes(r53, zone_id, names, control_domain)
    log(f"done: added {total} records")
    return 0


if __name__ == "__main__":
    sys.exit(main())
