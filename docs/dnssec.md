# DNSSEC

DNSSEC signing is available for every zone Cabalmail manages: the control-domain zone (owned by the bootstrap `terraform/dns` stack) and each mail-apex zone (owned by `terraform/infra/modules/domains`). It is opt-in per environment via the `TF_VAR_DNSSEC_ENABLED` GitHub environment variable (Terraform `var.dnssec_enabled`, default `false`).

When enabled, each stack creates one asymmetric KMS key (ECC_NIST_P256, in us-east-1 - a Route 53 requirement regardless of where the stack runs), a per-zone key-signing key (KSK), and turns on zone signing. KMS keys bill about $1/month each, so an enabled environment pays about $2/month (one key per stack).

## The one rule that matters

**Sign first. DS second.** A zone that is signed but has no DS record at the registrar is treated as insecure by resolvers - everything keeps working, nothing validates yet. A zone whose registrar publishes a DS record while the zone is *not* serving signed responses is **down** for every validating resolver (SERVFAIL). Every procedure below is ordered around this asymmetry: turning signing on is safe; publishing or removing DS records is the dangerous step and always happens against an already-consistent zone.

The same rule inverted governs disablement: **remove DS first, stop signing second** - and wait out resolver caches in between.

## Enabling DNSSEC for an environment

Run this in development first, then stage, then prod. The DS step requires registrar access and at least one wait, so budget a day per environment.

1. **Check the CI deploy policy.** The first apply uses KMS (`kms:CreateKey`, `kms:CreateAlias`, `kms:PutKeyPolicy`, ...) and the Route 53 DNSSEC APIs (`route53:CreateKeySigningKey`, `route53:EnableHostedZoneDNSSEC`, ...). The per-account CI policy is hand-managed; if these grants are missing the apply fails with AccessDenied and the grant has to be added in that account.
2. **Set the variable.** In the GitHub environment for the target account, set `TF_VAR_DNSSEC_ENABLED=true`.
3. **Apply the bootstrap stack.** The dns stage only runs when `terraform/dns/**` changes, so dispatch `infra.yml` manually with the `bootstrap` input checked. This signs the control-domain zone and outputs `control_domain_ds_record`.
4. **Apply the infra stack.** The same dispatch (or any infra push) signs every mail-apex zone and outputs `mail_domain_ds_records`.
5. **Verify signing before touching the registrar.** For each apex:

   ```sh
   # RRSIG present in the answer once signing is live
   dig +dnssec @8.8.8.8 mail-admin.<apex> TXT
   # KSK visible
   dig +dnssec @8.8.8.8 <apex> DNSKEY
   ```

   Wait until RRSIGs appear and the zone's old (unsigned) TTLs have expired - give it 24 hours after the apply.
6. **Publish DS records at each registrar.** Copy each zone's `ds_record` output value to the corresponding domain registration (same console as the nameserver delegation, see [registrar.md](./registrar.md)). The control domain and each mail apex are separate registrations; each needs its own DS record.
7. **Verify the chain of trust.**

   ```sh
   # AD flag set = a validating resolver accepted the chain
   dig +dnssec @8.8.8.8 mail-admin.<apex> TXT | grep flags
   # whois shows the DS at the registry
   whois <apex> | grep -i dnssec
   ```

   [DNSViz](https://dnsviz.net/) gives a full-chain visualization if anything looks off.
8. **Watch mail flow.** DMARC/SPF/MX lookups now carry signatures. Watch the smtp tiers' CloudWatch logs and the DMARC dashboard for a day before promoting the change to the next environment.

## Disabling DNSSEC (rollback)

Strictly in this order:

1. Delete the DS record at the registrar (every apex being disabled).
2. Wait at least 24 hours - until the DS TTL plus the parent zone's TTL have expired everywhere. Validating resolvers must stop expecting signatures before the zone stops producing them.
3. Set `TF_VAR_DNSSEC_ENABLED=false` and apply (bootstrap stage via manual dispatch, then infra). Terraform disables signing, deactivates and deletes the KSKs, and schedules the KMS keys for deletion (7-day window).

Out-of-order rollback - turning off signing while a DS record is still published - takes the domain down for validating resolvers. There is no faster path; the wait is the rollback.

## KSK rotation (yearly)

AWS's guidance for KMS-backed KSKs is to rotate roughly yearly. Automatic KMS rotation does not exist for asymmetric keys, so rotation is a double-signature dance. Using the console or CLI against one zone at a time:

1. Create a second KSK on the zone backed by a new KMS key (`aws route53 create-key-signing-key`). The zone now publishes both DNSKEYs and signs with both.
2. Add the new KSK's DS record at the registrar *alongside* the old one.
3. Wait 24+ hours (parent TTL).
4. Remove the old DS record at the registrar.
5. Wait 24+ hours again.
6. Deactivate and delete the old KSK, then schedule its KMS key for deletion.
7. Update the Terraform state to match (the KSK resource's `key_management_service_arn` now points at the new key): change the key resource, apply, and verify the plan is a no-op against the rotated zone.

In practice, for a solo-operator system it is simpler to rotate by zone-rebuild during a maintenance window: disable DNSSEC entirely (procedure above), let caches drain, re-enable with a fresh key. Both paths are valid; the double-DS dance avoids the unsigned window.

## Retiring a mail apex / environment teardown

The mail zones no longer set `force_destroy`, so `terraform destroy` refuses to delete a zone that still contains records (address records are created out of band by the `new` Lambda). To retire an apex:

1. If DNSSEC is enabled: remove the registrar DS record, wait 24h, disable signing for that zone.
2. Revoke or delete the zone's address records (the admin app, or `aws route53 change-resource-record-sets`). Only the apex NS and SOA records may remain.
3. Remove the apex from `TF_VAR_MAIL_DOMAINS` and apply; the empty zone deletes cleanly.

An environment teardown (`destroy_terraform.yml`) with DNSSEC enabled fails at the zone-deletion step unless signing was disabled first - that is deliberate; follow steps 1-2 for every apex before tearing down.
