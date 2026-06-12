# Backups

Mail is stored in AWS Elastic File System, and address data is stored in DynamoDB. AWS EFS is designed to achieve [99.999999999% (eleven nines) durability](https://aws.amazon.com/efs/faq/#Data_protection_.26_availability). AWS does not publish a durability rating for DynamoDB, but they [do say](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html#ddb_highavailability) that they replicate DynamoDB tables across multiple availability zones for "high durability". But however much you may trust AWS's assurances, they cannot protect you from users deliberately deleting mail and then changing their mind.

If you want Cabalmail to establish backups for you, set the `backup` input variable to `true`. Doing this may prevent clean destruction of a Cabalmail stack. If you would prefer to roll your own backups, AWS publishes instructions for backing up [EFS](https://docs.aws.amazon.com/efs/latest/ug/efs-backup-solutions.html) and [DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Backup.Tutorial.html).

Cabalmail sets `prevent_destroy` on the backup vault, so enabling Cabalmail backups will prevent a complete clean up by `terraform destroy`.

# Everyday Use

See the [User Manual](./user_manual.md) for instructions on using the included application for creating and revoking email addresses, and for managing user access.

You _could_ use a Cabalmail system along with client-side spam filters, but I recommend against it. Client-side spam filters process mail only after your servers have received and processed it. This hides the spam from you at the cost of gradually (or not-so-gradually) increasing the load on your infrastructure. By making your spam visible, you can easily intercede to reduce load on your infrastructure and keep humming along with small machines. Also, you eliminate false positives; never again will important mail be misidentified as junk.

You also _could_ create a single address on a Cabalmail system and just give that out to everyone like a normal address. But if you do, get ready to take a fresh look at those client-side spam filters.

# Monitoring

Setting `TF_VAR_MONITORING` to `true` in a GitHub environment adds [monitoring](./monitoring.md) infrastructure. Setting up monitoring is not turn-key. There are many manual steps involved in establishing alert thresholds, communication, configuration, etc. Once established, there are some run books in [the operations/runbooks directory](./operations/runbooks) that you can use as the basis for incident response. These are provided as templates. You should modify them as appropriate for your use cases and requirements.

# NLB access logs

The mail NLB writes TLS-connection access logs (the IMAPS listener; SMTP listeners are TCP passthrough and produce none) to a dedicated, versioned, 180-day-lifecycled S3 bucket. See [NLB access logs](./nlb-access-logs.md) for what the logs do and do not cover and for the Athena setup to query them.

# NAT and private-subnet egress

Every private-subnet container reaches the internet and all AWS service APIs through the VPC's NAT, and the VPC has no VPC endpoints, so NAT health is load-bearing: if egress breaks, outbound mail stalls, the `/send` Lambda hangs, and the mail tiers stop shipping logs to CloudWatch even though the containers keep running. See [NAT and private-subnet egress](./nat.md) for the two NAT modes (EC2 instances or NAT Gateways), the gateway-based instance-mode bootstrap, and how to diagnose an egress outage.

# Quiescing a non-prod environment

The `quiesce` GitHub workflow scales a development or stage environment's running compute (ECS services, the ECS-instance ASG, NAT instances) to zero so it stops accruing hourly charges. Data is preserved. The workflow refuses to run against prod. See [Quiesce: scale a non-prod environment to zero](./quiesce.md) for the full list of what gets scaled, what is preserved, and how to make the quiesce durable across other Terraform runs.

# IMAP full-text search index

The `imap` container ships [dovecot-fts-flatcurve](https://github.com/slusarz/dovecot-fts-flatcurve) (pinned upstream tag and commit baked into `docker/imap/Dockerfile`, licence preserved at `/usr/share/doc/fts-flatcurve/` inside the image). The plugin gives `/search_envelopes` an inverted index instead of a sequential body scan; configuration lives in `docker/imap/configs/dovecot/90-fts.conf`.

## What the plugin indexes (and what it does not)

Header and body text only, per `fts_autoindex = yes`. The autoindex exclude list skips Trash — the only folder `/search_envelopes` excludes by default — so we don't waste EFS throughput indexing mail we never search. Spam and Junk are searchable (users do need to find misclassified mail), so they're indexed too. Attachments are not decoded — searching for a phrase that lives only inside a PDF or Office document will not find it. That is the design.

Each user's index sits next to their `Maildir` on EFS (under per-mailbox `.fts/` directories). Steady-state index size is roughly 10-20% of mail volume.

## One-shot reindex when the plugin first lights up

When the FTS plugin first ships to an environment, no mailbox has an index yet. New mail will autoindex as it arrives, but historical mail stays invisible to FTS searches until you backfill. `fts_enforced = yes` is set, so a SEARCH that needs unindexed mail returns an error rather than silently falling back to a sequential scan — the rescan is a required deploy step, not a "do it later" nicety.

From inside an `imap` task (`aws ecs execute-command` into the running container), reindex every existing user:

```bash
for u in $(cut -d: -f1 /etc/passwd | awk '$1 ~ /^[a-z0-9]/ && $1 != "admin"'); do
  doveadm fts rescan -u "$u"
done
```

For one user:

```bash
doveadm fts rescan -u "$USERNAME"
```

`doveadm fts rescan` queues the rebuild; the actual indexing runs on the next mailbox access (or immediately if `doveadm index -u $USER '*'` is run afterwards). On a multi-gigabyte mailbox the indexer burns CPU and EFS throughput for several minutes per user. Run during off hours.

## EFS throughput during a rescan

Reindexing is small-file-heavy. If a backfill saturates the filesystem, raise `provisioned_throughput_in_mibps` in [`terraform/infra/modules/efs/main.tf`](../terraform/infra/modules/efs/main.tf) for the duration of the rescan and roll it back once the per-user `.fts/` directories stop growing. The plan's expectation is that the steady-state footprint sits well inside whatever throughput the mail tier already needs, so this is a rollout-window concern only.

## Backup interaction

The `.fts/` directories are derived data. If AWS Backup includes them, restores carry the index with them and search works immediately after restore. If a restore arrives with missing or corrupt `.fts/` content, re-run the rescan above to rebuild from the underlying `Maildir` — no mail is lost either way. There is no special handling required in Terraform; the EFS backup plan already covers the entire filesystem.

## Search-content logging policy

Per the privacy goal in `docs/0.9.x/imap-search-plan.md`, the system does not log query terms, result UIDs, or result counts. Dovecot's `mail_debug = no` and `auth_debug = no` defaults keep SEARCH arguments out of syslog, and `docker/imap/configs/dovecot/10-logging.conf` does not flip either on. If you ever enable `mail_debug` for incident investigation, disable it again as soon as the investigation is done — leaving it on would route SEARCH arguments through the container's stderr into CloudWatch Logs, which is exactly what the privacy stance disallows. The same applies to `fts_flatcurve_debug` and any `log_debug` toggles: do not bake them into the image.

# Test fixtures and pre-promotion verification

Setting `TF_VAR_SINKHOLE` to `true` in a non-prod GitHub environment deploys the [SMTP sinkhole test fixture](./0.9.x/sinkhole-test-harness-plan.md), a tiny configurable SMTP listener fronted by Cloud Map. It exists so test sequences that need a deterministic 4xx response on demand (queue persistence, DSN handling, large-message timeouts, STARTTLS fallback) are reproducible. The flag is refused in prod by the Terraform variable's validation block.

The first runbook that uses it is the [queue-persistence test runbook](./testing/queue-persistence.md): verifies that a message deferred by an in-flight retry survives an ECS task replacement.
