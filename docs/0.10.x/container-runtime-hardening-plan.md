# Container Runtime Hardening Plan

## Context

The three mail-tier containers (imap, smtp-in, smtp-out) and the optional monitoring tier (prometheus, alertmanager, grafana, exporters, kuma, ntfy, healthchecks) were lifted off the original Chef/EC2 baseline during the 0.4.x containerisation work. The migration faithfully preserved the *behaviour* of the EC2 install — same sendmail `.mc` macros, same Dovecot conf, same supervisord process tree — but did not replace EC2-era assumptions with container-era ones. The result is a stack of `amazonlinux:2023`-based images running as root with full Linux capabilities, mounting EFS volumes without `noexec`, signing DKIM for any source IP that can reach the daemon, accepting unbounded message sizes, and shipping a fail2ban that is wired into supervisord but commented out.

None of these have produced an incident. Together they form a meaningful blast-radius surface that we can shrink in deliberate, mostly-additive PRs.

This plan is the container-and-mail-tier counterpart to [`application-surface-hardening-plan.md`](./application-surface-hardening-plan.md) (which covers the Lambda Python code) and [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md) (which catches the IaC-flaggable issues). The Trivy IaC scanner from that plan will pick up a subset of these findings once it lands; this plan addresses the architectural and runtime-config issues that scanners would not catch.

Six themes:

1. **Runtime privilege posture.** Drop `NET_ADMIN`, set `readOnlyRootFilesystem`, `noNewPrivileges`, and a `user` override per container.
2. **Image supply chain.** Pin `amazonlinux:2023` and the third-party Prometheus/Grafana/etc. images to digest; standardise the rebuild cadence; enable ECR scan-on-push.
3. **Sendmail hardening.** Add `confMAX_MESSAGE_SIZE`, `confCONNECTION_RATE_THROTTLE`, `confMAX_DAEMON_CHILDREN`, `restrictmailq`. Drop weak AUTH mechanisms on smtp-in. Atomic config writes.
4. **Dovecot hardening.** Flip `disable_plaintext_auth = yes`. Add login-attempt rate limiting via Dovecot's own knobs (the only viable replacement for fail2ban in the container-network model).
5. **OpenDKIM scope.** Replace `TrustedHosts = 0.0.0.0/0` with `127.0.0.1` + the loopback shape sendmail actually uses to hand mail to the milter.
6. **EFS posture.** Add `transit_encryption = ENABLED` to the IMAP mailstore mount; enforce `nosuid` and (where feasible) `noexec` on the mailstore filesystem; clean up the fail2ban dead code.

The themes ship as five phases. Phase 4 (Dovecot rate limiting) is the highest-touch piece — it changes auth behaviour. The rest are largely transparent.

## Goals

- Every mail-tier container runs with `linuxParameters.initProcessEnabled = true`, the `no-new-privileges` flag set, and only the capabilities it actually needs (default: drop all; opt back in per tier if and when required). `readOnlyRootFilesystem = true` is the target wherever a tier can support it, but the mail tiers regenerate their entire `/etc/mail` + `/etc/opendkim` config surface at runtime (see Phase 2), so ROFS for those is conditional on the seeding/relocation work landing — not a given. The monitoring tier, which does no runtime config regeneration, gets ROFS unconditionally.
- No tier requests `NET_ADMIN` once fail2ban is gone. The capability was added solely to support fail2ban's iptables manipulation, and fail2ban has been commented out of supervisord since before this audit.
- Every container image — first-party and third-party — referenced by ECS is pinned to a SHA256 digest, not a floating tag. Renovate/Dependabot opens upgrade PRs.
- OpenDKIM signs mail only from local sendmail (loopback). A misconfigured network rule that exposes port 25 publicly does not turn the container into a free DKIM-signing oracle for arbitrary external senders.
- Dovecot rejects plaintext auth when the connection is not TLS-protected (which, behind the NLB, is "always — TLS terminates at NLB for IMAP, and end-to-end for submission"). Successive failed logins from the same source IP back off via Dovecot's `auth_failure_delay` and `process_limit`-style knobs.
- Sendmail refuses messages larger than 50 MB, caps daemon child processes, throttles connection bursts from a single IP, and refuses non-postmaster mail-queue inspection.
- The IMAP mailstore is mounted with transit encryption on. EFS volumes use `nosuid` at the mount layer.
- The image rebuild path catches new CVEs within a defined window (nightly Trivy scan; quarterly base-image bump cadence).

## Non-goals

- Replacing sendmail. There is a separate [`docs/unreleased/sendmail-replacement.md`](../unreleased/sendmail-replacement.md) plan; the hardening here applies *to the current sendmail* and is no-impact on a future replacement (the macros described are universal enough that any maintained MTA has equivalents).
- Replacing supervisord with a multi-container task definition (one process per container). Cost-vs-complexity calculus is unchanged from the 0.4.x decision; revisit if/when the supervisord boundary becomes a problem.
- Adding a sidecar fail2ban or Suricata pattern. The container-network model means container-level packet inspection is the wrong layer; rate limiting belongs at the NLB or in a WAF (out of scope here — see [`identity-iam-hardening-plan.md`](./identity-iam-hardening-plan.md) for the per-endpoint rate-limit story).
- Replacing the `amazonlinux:2023` base with a distroless variant. The sendmail + dovecot + opendkim + supervisord stack would not survive on distroless without significant work.
- Re-encoding TLS-1.2-to-TLS-1.3 ciphers. TLS 1.2 with sane cipher preferences is the floor we ship today; TLS 1.3 is supported by both Dovecot and sendmail and we should opportunistically negotiate it, but the floor stays at 1.2 for compatibility with older IMAP clients on the user's bring-your-own-MUA path.
- Seccomp/AppArmor profiles. ECS support is partial and per-runtime; revisit when the runtime story is stable.
- Migrating to ECS Fargate (the no-EC2 model). Fargate constrains some of what we'd want to do here (capabilities, mount options); the EC2 launch model is fine for our shape.

## Current state (audit)

### Runtime privilege

All three mail tiers add `NET_ADMIN` ([`terraform/infra/modules/ecs/task-definitions.tf:63-67, 134-138, 242-246`](../../terraform/infra/modules/ecs/task-definitions.tf)). The capability was added so fail2ban could manipulate iptables. fail2ban is commented out in every tier's supervisord config: [`docker/imap/supervisord.conf:37-40`](../../docker/imap/supervisord.conf), [`docker/smtp-in/supervisord.conf:38-40`](../../docker/smtp-in/supervisord.conf), [`docker/smtp-out/supervisord.conf:51-54`](../../docker/smtp-out/supervisord.conf). The capability is unused.

No `readOnlyRootFilesystem`, no `linuxParameters.initProcessEnabled`, no `securityContext.noNewPrivileges`. All containers run as root for the duration of supervisord; sendmail and dovecot drop privileges via their own `User=` directives once spawned, but the container's process 1 is root, and any process the entrypoint shells out to runs as root by default.

The non-mail tiers fare somewhat better. Prometheus/Alertmanager/Grafana inherit non-root users from their upstream images, but the Dockerfile `USER` directive is not set explicitly, so a change to upstream image conventions would silently switch them.

### Image supply chain

All `FROM` lines reference floating tags: `amazonlinux:2023`, `prom/prometheus:v3.5.0`, `grafana/grafana:11.4.0`, etc. None are digest-pinned. The CI pipeline (`.github/workflows/app.yml`) rebuilds on push but does not record provenance; tag re-pulls are silent on the next rebuild.

ECR repositories are created in [`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf) without `image_scanning_configuration { scan_on_push = true }` and without `image_tag_mutability = "IMMUTABLE"`. Re-tagging a published image to a different SHA is permitted.

### Sendmail config

All three templates set `confPRIVACY_FLAGS` but omit `restrictmailq` in two of them ([`docker/templates/in-sendmail.mc:8`](../../docker/templates/in-sendmail.mc), [`docker/templates/out-sendmail.mc:8`](../../docker/templates/out-sendmail.mc)). The IMAP template has `restrictqrun` but not `restrictmailq`.

No template defines `confMAX_MESSAGE_SIZE`, `confMAX_DAEMON_CHILDREN`, or `confCONNECTION_RATE_THROTTLE`. A burst of inbound connections from a single IP is bounded only by the per-tier ECS container's memory ceiling.

The smtp-in template enables a generous AUTH mechanisms list — `EXTERNAL GSSAPI DIGEST-MD5 CRAM-MD5 LOGIN PLAIN` ([`docker/templates/in-sendmail.mc:27-29`](../../docker/templates/in-sendmail.mc)) — but smtp-in is the inbound relay; it should not be doing AUTH at all (submission auth is on smtp-out via Dovecot). DIGEST-MD5 and CRAM-MD5 are weak by modern standards (RFC 6331 obsoleted DIGEST-MD5).

[`docker/shared/generate-config.sh`](../../docker/shared/generate-config.sh) writes sendmail maps directly to their final paths (`/etc/mail/virtusertable`, etc.) rather than write-temp-then-rename. A SIGHUP or restart that lands mid-write reads a partial file. Race window is small (millisecond-scale) but non-zero.

### Dovecot config

Both IMAP and SMTP-OUT submission set `disable_plaintext_auth = no` ([`docker/imap/configs/dovecot/10-auth.conf:1`](../../docker/imap/configs/dovecot/10-auth.conf), [`docker/smtp-out/configs/dovecot/10-auth.conf:1`](../../docker/smtp-out/configs/dovecot/10-auth.conf)). The architectural justification is that TLS terminates at the NLB for IMAP (port 993 → 143) and at Dovecot itself for submission (the NLB passes 587/465 through TCP unencrypted). Anything that talks to Dovecot inside the container's network namespace can therefore do plaintext auth. If the NLB is ever bypassed (operator running `kubectl port-forward`-equivalent, sidecar shipped, ECS Exec session for debugging), Dovecot will accept credentials in clear.

`ssl_min_protocol = TLSv1.2` is set in the entrypoint [`docker/shared/entrypoint.sh:110`](../../docker/shared/entrypoint.sh). No explicit cipher list — Dovecot's default is fine but unspecified is unspecified.

IMAP `mail_max_userip_connections = 100` is set. No `login_max_processes`, no `auth_failure_delay`, no `auth_cache_size` settings that would slow down brute-force.

### OpenDKIM scope

[`docker/shared/generate-config.sh:230`](../../docker/shared/generate-config.sh) writes `/etc/opendkim/TrustedHosts` with a single line: `0.0.0.0/0\n`. [`docker/smtp-out/configs/opendkim.conf:15-16`](../../docker/smtp-out/configs/opendkim.conf) references the same file for both `ExternalIgnoreList` and `InternalHosts`. The effect is "any source IP is treated as internal," meaning OpenDKIM signs any matching `From:` regardless of source.

The blast radius is moderated by the SigningTable: [`gen_dkim_signingtable`](../../docker/shared/generate-config.sh) writes `*@<subdomain>.<tld> cabal._domainkey.<subdomain>.<tld>` for each configured subdomain. A message with `From: arbitrary@external.com` would not match any SigningTable entry and would not be signed. So the practical risk is bounded: an attacker who reaches port 25 on the container *and* presents a `From:` on a domain Cabalmail signs (which they cannot do unless they also pass the dovecot auth layer for that user) gets a signature.

Still, defence in depth: the failure mode is "any single piece of the chain breaks and we are an open DKIM signer." That is the kind of finding worth fixing while it is cheap.

### EFS posture

The IMAP task's EFS mount is plain: `file_system_id = var.efs_id; root_directory = "/"` ([`terraform/infra/modules/ecs/task-definitions.tf:80-86`](../../terraform/infra/modules/ecs/task-definitions.tf)). No `transit_encryption`, no `authorization_config`. The smtp-out queue mount does set `transit_encryption = "ENABLED"` and uses an access point ([`task-definitions.tf:266-276`](../../terraform/infra/modules/ecs/task-definitions.tf:266)), so the model is there — it just was not retrofitted onto IMAP when the access-point pattern landed.

The EFS filesystem itself is encrypted at rest ([`terraform/infra/modules/efs/main.tf`](../../terraform/infra/modules/efs/main.tf)); transit encryption is the missing piece for IMAP.

Mount options for `noexec`/`nosuid`/`nodev` are not currently exposable through `efs_volume_configuration`. ECS sets reasonable defaults; the access-point posture is the practical control surface.

### fail2ban dead config

The supervisord entries are commented out; the entrypoint nevertheless writes `/etc/fail2ban/jail.local` with the VPC CIDR allowlist ([`docker/shared/entrypoint.sh:159-171`](../../docker/shared/entrypoint.sh)) and the `NET_ADMIN` capability is still requested. The image install also still pulls in `fail2ban` via `dnf install`. Code, capability, and runtime artefact are all present for a feature that is off.

## Target state

### Phase 1 — Drop fail2ban dead weight; drop NET_ADMIN

Each tier's `Dockerfile` removes `fail2ban` from the `dnf install` line and the `supervisord.conf` `[program:fail2ban]` blocks are deleted (not just commented). [`docker/shared/entrypoint.sh:159-171`](../../docker/shared/entrypoint.sh)'s jail.local stanza is removed.

[`terraform/infra/modules/ecs/task-definitions.tf`](../../terraform/infra/modules/ecs/task-definitions.tf) drops the `linuxParameters.capabilities.add = ["NET_ADMIN"]` blocks on all three mail tiers.

This is a no-op for behaviour (nothing using the cap) and a real reduction in attack surface (escape-to-host scenarios that exploit `NET_ADMIN` are off the table).

### Phase 2 — Container runtime posture

The capability-and-privilege posture applies cleanly to every tier:

```hcl
linuxParameters = {
  initProcessEnabled = true
  capabilities       = { drop = ["ALL"], add = [] }  # opt back in below
}
```

`dockerSecurityOptions = ["no-new-privileges:true"]` on each container.

Per-tier capability adds:

- **imap**: none beyond defaults. sendmail/dovecot drop privileges internally.
- **smtp-in**: none.
- **smtp-out**: none (DKIM key access is via filesystem permissions, not capabilities).

#### readOnlyRootFilesystem is not a flag flip for the mail tiers

The mail tiers are heavy *runtime* config-mutators, not just at startup. `reconfigure.sh` runs as a sidecar loop and re-runs the full config generation on every address change (SQS-triggered) and on the periodic fallback ([reconfigure.sh:30-84](../../docker/shared/reconfigure.sh)). Each pass writes across the root filesystem; with a read-only root and `set -euo pipefail`, the first `EROFS` aborts the regeneration, and new addresses/subdomains silently stop propagating — the periodic fallback fails too, so there is no self-heal.

The full writable-path inventory — everything that needs a writable mount before ROFS can be set on a mail tier:

| Path | Written by | When |
|---|---|---|
| `/etc/mail/{access,virtusertable,mailertable,relay-domains,local-host-names,masq-domains}` | `generate-config.sh` | startup + every reconfigure |
| `/etc/mail/*.db` | `makemap` (reconfigure), `make -C /etc/mail` (entrypoint) | startup + every reconfigure |
| `/etc/mail/sendmail.mc`, `/etc/mail/sendmail.cf` | entrypoint render + `make` | startup |
| `/etc/opendkim/{KeyTable,SigningTable,TrustedHosts}` | `generate-config.sh` | startup + every reconfigure (smtp-out) |
| `/etc/opendkim/keys/cabal` | entrypoint | startup (smtp-out) |
| `/etc/aliases`, `/etc/aliases.dynamic`, `/etc/aliases.db` | entrypoint + reconfigure (`newaliases`) | startup + every reconfigure (imap) |
| `/etc/dovecot/conf.d/{10-ssl,05-login}.conf` | entrypoint | startup (imap, smtp-out) |
| `/etc/dovecot/master-users` | entrypoint (`htpasswd`) | startup (imap) |
| `/etc/pki/tls/{certs,private}/*` | entrypoint | startup |
| `/usr/bin/cognito.bash` | entrypoint | startup |
| `/etc/fail2ban/jail.local` | entrypoint | startup (removed in Phase 1) |
| `/var/lib/rsyslog` | entrypoint (`mkdir`) | startup |
| `/etc/hosts` | `hosts-pin.sh` | startup + on IMAP IP change (smtp-in) |
| `/tmp` (scratch via `mktemp`) | `generate-config.sh` | startup + every reconfigure |

Two tmpfs mounts (`/tmp`, `/var/run`) — the original scope of this phase — cover almost none of this. The real mutation surface is the mail config itself.

**The tmpfs-shadowing trap.** `/etc/mail` and `/etc/opendkim` cannot simply be tmpfs-mounted: both ship image-baked content. `/etc/mail` holds the `sendmail-cf` m4 sources and `Makefile` that `make -C /etc/mail` needs, the COPYed `sendmail.mc.template`, and (smtp-out) the static `access` map; `/etc/opendkim` is laid out by the package. An empty tmpfs over either shadows that content, so the entrypoint would have to *seed* the tmpfs (copy baked files in) before generating — a change to entrypoint ordering, not just a task-def edit.

Three ways to reconcile ROFS with this, in increasing order of effort and payoff:

1. **Posture-without-ROFS for the mail tiers (default for 0.10.x).** Apply `drop=ALL`, `no-new-privileges`, and `initProcessEnabled` to imap/smtp-in/smtp-out but leave `readOnlyRootFilesystem` unset. Keeps the bulk of the hardening value and avoids the seeding problem entirely. This is the pragmatic landing spot, given that "rewrite `/etc/mail` from DynamoDB" is these images' normal operation.
2. **Full tmpfs + entrypoint seeding.** tmpfs-mount every writable path above and seed `/etc/mail`/`/etc/opendkim` from baked copies at entrypoint. Achieves ROFS, but the entire mail-config surface is writable tmpfs anyway, so the marginal benefit over option 1 is modest and the entrypoint complexity is real. The tmpfs shape (ECS on EC2 supports it via `linuxParameters.tmpfs`):

   ```hcl
   linuxParameters = {
     initProcessEnabled = true
     tmpfs = [
       { containerPath = "/tmp",     size = 64,  mountOptions = ["rw","nosuid","nodev","noexec"] },
       { containerPath = "/var/run", size = 32,  mountOptions = ["rw","nosuid","nodev"] },
       # ...plus /etc/mail, /etc/opendkim, /etc/dovecot/conf.d, /etc/pki/tls, /var/lib/rsyslog, /etc/aliases*
     ]
     capabilities = { drop = ["ALL"], add = [] }
   }
   ```

3. **Relocate generated config to a single writable prefix.** Refactor `generate-config.sh`, `reconfigure.sh`, and the daemon configs so all generated maps/tables/aliases live under one writable path (e.g. `/run/cabal/...`) and point sendmail/dovecot/opendkim at it. Cleanest end state — the actual root stays read-only — but a meaningful refactor that touches the daemon config wiring.

The monitoring tier does no runtime config regeneration and is a clean ROFS candidate; it can go read-only independently of the mail tiers and should not be gated on this decision.

#### Recommendation

Ship option 1 for the three mail tiers in 0.10.x (posture hardening without ROFS), set `readOnlyRootFilesystem = true` on the monitoring tier, and capture option 3 as a follow-up if ROFS on the mail tiers later becomes a requirement. The entrypoint and reconfigure write paths are the gating constraint here, not the capability drop.

The posture changes are still the highest-touch part of this plan. Migration order is dev → stage → prod with at least one mail-roundtrip end-to-end test per environment between flips. Other things to verify:

- `/var/log` paths used by sendmail/dovecot. Stdout/stderr-route them (already mostly done) so no on-disk log file is needed.
- Port binding under `cap_drop: ALL` (see Open questions — `CAP_NET_BIND_SERVICE` may be required and need re-adding per tier).

Pre-flight: a development-environment soak under load is essential before stage rollout.

#### Phase 2a as implemented (0.10.8) — capability tightening

The 0.10.4 add-back sets were flagged to tighten during the soak. Reviewed per tier against what each actually runs:

- **imap and smtp-out — already minimal.** Both run `sync-users.sh` (`useradd`/`install -o` → CHOWN/FOWNER/DAC_OVERRIDE), fork privilege-dropped daemon children (SETUID/SETGID/KILL), bind <1024 (NET_BIND_SERVICE), and chroot dovecot login (SYS_CHROOT); smtp-out additionally resolves submission auth against the system passwd db (`userdb { driver = passwd }`), so it genuinely needs the synced users. Nothing to drop.
- **smtp-in — dropped CHOWN, FOWNER, DAC_OVERRIDE.** A pure relay (sendmail only, no dovecot; its mailertable routes every hosted-domain message to imap over SMTP, no local delivery), so it resolves no local OS users — `sync-users.sh` was running on it only as a uniform-entrypoint artifact. The entrypoint now skips the sync there, removing the only consumers of those three caps; the remaining set is KILL, NET_BIND_SERVICE, SETUID, SETGID (sendmail's own mail/smmsp privilege drops, kept absent an empirical signal to remove them).

Shipped as two ordered deploys: (1) the entrypoint `sync-users` gate via app.yml, with smtp-in verified healthy and relaying; then (2) the task-def cap drop via Terraform (smtp-in marker v3 → v4). The cap drop must not roll before the gate is live, or smtp-in startup would fail without caps it is still using.

### Phase 3 — Image digest pinning + ECR scan on push

Three pieces:

1. Each Dockerfile's `FROM` line gains a digest. `FROM amazonlinux:2023@sha256:<...>`. Renovate config gets a `docker` ecosystem entry that auto-bumps the digest when the upstream tag advances.
2. The ECS task definitions reference ECR images by digest, not by tag. The image-tag-via-SSM pattern stays; the value in SSM is the *digest* (`<repo>@sha256:<...>`) instead of `<repo>:sha-<8>`. `.github/scripts/deploy-ecs-service.sh` extracts the digest from `docker buildx --metadata-file` and writes it to SSM.
3. ECR repositories gain `image_scanning_configuration { scan_on_push = true }` and `image_tag_mutability = "IMMUTABLE"` in [`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf). Findings surfaced via the existing `app.yml` deploy job (poll `aws ecr describe-image-scan-findings` after push; warn on HIGH/CRITICAL until a baseline is established, then fail).

Nightly Trivy scan against the current digest-pinned images, results to GitHub Code Scanning (same surface as the Trivy IaC scan from [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md)).

#### Phase 3 as implemented (0.10.6)

Reconciled against the codebase as it actually stood, Phase 3 shipped three of the four pieces above; piece 2 was dropped.

- **Piece 1 (digest pinning) — shipped.** Every Dockerfile `FROM` is pinned to `tag@sha256:<digest>`: the three mail tiers and the sinkhole fixture on `amazonlinux:2023`, certbot-renewal on the Lambda Python base, and the monitoring images on their upstreams (the three ARG-driven monitoring FROMs — uptime-kuma, ntfy, healthchecks — were flattened to literal `tag@digest`). Automated bumps come from a new [`.github/dependabot.yml`](../../.github/dependabot.yml) scoped to the Docker ecosystem — Dependabot, not Renovate, since the repo already runs Dependabot's alert feed — with PRs targeting `stage`.
- **Piece 3 (scan-on-push + immutable tags) — already shipped.** [`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf) already sets `scan_on_push = true` and `image_tag_mutability = "IMMUTABLE"` on every repo (it landed with the 0.9.x build-deploy simplification). What was missing was *surfacing* the findings: `app.yml`'s docker job now reads the scan result and warns on HIGH/CRITICAL ([`.github/scripts/ecr-scan-report.sh`](../../.github/scripts/ecr-scan-report.sh)), and a nightly [`.github/workflows/image-scan.yml`](../../.github/workflows/image-scan.yml) runs Trivy against the running prod images and uploads SARIF to Code scanning.
- **Piece 2 (digest references in the ECS task definitions) — dropped.** Its premise ("re-tagging a published image to a different SHA is permitted") is false now that `image_tag_mutability = IMMUTABLE` is in force: each `cabal-<tier>:sha-<8>` tag is already permanently bound to one digest, so a digest reference in the task def buys no additional integrity. Against that ~zero benefit, the cost is real — the deploy path stores one shared git-sha tag in `/cabal/deployed_image_tag` for all tiers ([`locals.tf`](../../terraform/infra/modules/ecs/locals.tf) `tier_image`), and digests are per-image, so the change would force a per-tier SSM refactor of `refresh-ssm-from-running.sh`, `deploy-ecs-service.sh`, and the task-def wiring, a path that has already caused production incidents. If task-def digest references ever become a hard requirement, do it as part of moving to per-tier image parameters, not as a bolt-on.

### Phase 4 — Dovecot plaintext-off + login throttling

Flip [`docker/imap/configs/dovecot/10-auth.conf:1`](../../docker/imap/configs/dovecot/10-auth.conf) and [`docker/smtp-out/configs/dovecot/10-auth.conf:1`](../../docker/smtp-out/configs/dovecot/10-auth.conf) to `disable_plaintext_auth = yes`. Add to both configs:

```
auth_failure_delay = 2 secs
auth_mechanisms = plain login
```

Add to IMAP:

```
service imap-login {
  process_limit = 1024
  client_limit = 1
}
service auth {
  client_limit = 4096
}
```

And to submission:

```
service submission-login {
  process_limit = 512
  client_limit = 1
}
```

The TLS terminator question: IMAP traffic arrives at the container in clear (NLB terminates 993→143). `disable_plaintext_auth = yes` would reject the IMAP login path unless we tell Dovecot the connection is *effectively* TLS. Two options:

1. **`login_trusted_networks = <NLB subnet CIDR>`.** Dovecot treats sessions from these source IPs as already-TLS for auth purposes. The NLB source IP range is stable (the NLB IPs themselves are stable; backing them with proxy protocol is not configured today). Risk: anyone inside the VPC who can connect to the IMAP service port can bypass TLS. Acceptable given the VPC posture.
2. **End-to-end TLS (NLB passthrough mode), Dovecot terminates TLS itself.** Higher operational complexity; cert rotation has to land at Dovecot via SSM/EFS. Defer.

Recommendation: option (1), with the NLB-subnet CIDR plumbed as an env var (`LOGIN_TRUSTED_NETWORKS`) injected by the ECS task definition. The entrypoint writes it to the dovecot config.

#### Phase 4 reconnaissance (verified live 2026-06-06)

The option-(1) assumption was checked against the running infrastructure before committing to it; it holds, with one refinement.

- **Source IP is the NLB, not the client — confirmed.** `preserve_client_ip.enabled = false` on the `cabal-ecs-imap-tg` target group (`target_type = "ip"`, `protocol = "TCP"`, port 143) in **both prod and stage** (`aws elbv2 describe-target-group-attributes`). It is not set in Terraform, so the AWS default governs, and for an IP-type target group with a TCP/TLS protocol that default is *disabled*. So the NLB SNATs and Dovecot sees the NLB node's private IP — exactly what `login_trusted_networks` needs. (The IMAP NLB listener is TLS-terminating, 993 -> 143, which is *why* plaintext reaches the container; submission is the opposite, see below.)
- **The trusted range is the NLB's public-subnet CIDRs, and it is per-environment** (verified 2026-06-06):
  - **prod** (VPC `10.0.0.0/16`): two public subnets, `10.0.64.0/19` (us-east-1a) + `10.0.96.0/19` (us-east-1b). They tile the `10.0.64.0/18` "public tier" exactly; the private subnets live in the separate `10.0.0.0/18`.
  - **stage**: a single public subnet `10.64.64.0/18` (us-east-1a).
- **Derive the list; do not hardcode and do not collapse.** `LOGIN_TRUSTED_NETWORKS` should be emitted per-env from the NLB's actual subnet CIDRs (Terraform) and passed as a space-separated list — Dovecot's `login_trusted_networks` accepts a list natively. Resist collapsing prod's two /19s into `10.0.64.0/18`: it is exact *today*, but it loses the auto-tracking property — it would miss a future us-east-1c public subnet (outside the /18) and would silently trust anything later carved into `10.0.64.0/18` that is not an NLB subnet. Deriving from the subnet data tracks the source of truth; a literal does not.
- **Submission (587/465) needs none of this.** Those listeners are TCP passthrough and Dovecot terminates TLS itself, so `disable_plaintext_auth = yes` works there directly, with no trusted-networks marking.
- **Guard the coupling.** If `preserve_client_ip.enabled` is ever flipped to `true` (e.g. to log or rate-limit on real client IPs), the trusted-networks assumption breaks silently and *every* IMAP login starts failing. Tie the two together — at minimum a comment where the attribute is (un)set, ideally a check — so the dependency is not invisible.

For submission, NLB does TCP passthrough; Dovecot already terminates TLS; `disable_plaintext_auth = yes` works out of the box without trusted-networks games.

### Phase 5 — Sendmail and OpenDKIM hardening

#### Sendmail .mc templates

Add to all three:

```m4
define(`confMAX_MESSAGE_SIZE',         `52428800')dnl
define(`confMAX_DAEMON_CHILDREN',      `40')dnl
define(`confCONNECTION_RATE_THROTTLE', `5')dnl
define(`confREJECT_LOG_INTERVAL',      `3h')dnl
```

Append `restrictmailq` to `confPRIVACY_FLAGS` in [`docker/templates/in-sendmail.mc:8`](../../docker/templates/in-sendmail.mc) and [`docker/templates/out-sendmail.mc:8`](../../docker/templates/out-sendmail.mc).

Remove `DIGEST-MD5` and `CRAM-MD5` from `confAUTH_MECHANISMS` in [`docker/templates/in-sendmail.mc:27-29`](../../docker/templates/in-sendmail.mc); for inbound relay, the right answer is to remove `AUTH` entirely (smtp-in does not need it — submission auth is on smtp-out via Dovecot). Cut to: `define('confAUTH_MECHANISMS', 'EXTERNAL')dnl` or remove the macro.

#### Atomic config writes

In [`docker/shared/generate-config.sh`](../../docker/shared/generate-config.sh):

```python
def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    print(f"  Generated {path}")
```

`os.replace` is atomic on POSIX filesystems.

#### OpenDKIM scope

[`docker/shared/generate-config.sh:230`](../../docker/shared/generate-config.sh) writes a tighter `TrustedHosts`:

```python
write("/etc/opendkim/TrustedHosts",
      "127.0.0.1\n::1\nlocalhost\n")
```

Sendmail hands mail to OpenDKIM via the milter socket on loopback; the only legitimate signing source is local. The SigningTable still constrains *which* domain to sign for, but now both axes (network position *and* From-domain match) have to be true.

### Phase 6 — EFS transit encryption on IMAP

[`terraform/infra/modules/ecs/task-definitions.tf:80-86`](../../terraform/infra/modules/ecs/task-definitions.tf) is updated to:

```hcl
volume {
  name = "mailstore"
  efs_volume_configuration {
    file_system_id     = var.efs_id
    root_directory     = "/"
    transit_encryption = "ENABLED"
    authorization_config {
      access_point_id = var.mailstore_access_point_id
      iam             = "DISABLED"
    }
  }
}
```

A new EFS access point on the mailstore (mirroring the existing `smtp_queue_access_point_id` pattern) constrains the IMAP task to `/maildir` (or wherever the existing mount root effectively points). Created in [`terraform/infra/modules/efs/main.tf`](../../terraform/infra/modules/efs/main.tf).

The access-point creation has to land *before* the task-definition change references it; that is one Terraform apply, since both files are in the same stack.

#### Phase 6 as implemented (0.10.7)

Shipped as **transit encryption only — no access point.** The sketch above mirrors the smtp-queue access point, but the mailstore is not analogous to the queue: it is a multi-user tree rooted at the EFS root `/` (mounted to `/home`, one maildir per user, each owned by that user's UID via `sync-users.sh`), whereas the queue is a single `/smtp-queue` subtree. An access point would therefore have to be `root_directory = "/"` with no `posix_user` — any posix override squashes the per-user ownership and every mailbox reads empty — and `iam = "DISABLED"` (the queue AP already disables IAM "for parity with the IMAP mount"). That is a transparent pass-through: zero gain over plain transit encryption, plus a data-path footgun if the root were ever mis-set. And `transit_encryption = "ENABLED"` does not require an access point — the queue pairs them only because it needed the AP to pin `/smtp-queue` and set the creation owner.

So the change is just `transit_encryption = "ENABLED"` on the existing `root_directory = "/"` mailstore volume, with the imap revision marker bumped v3 -> v4 so the volume edit actually deploys (a volume edit, like a `container_definitions` edit, is otherwise held back by `ignore_changes`). The smtp-out tier already runs `ENABLED` on these same ECS EC2 hosts, so the transit path is proven; the roll is one task replacement (brief IMAP blip). If per-tier IAM auth on EFS is ever wanted (the identity-IAM-hardening plan), add the access point then with `iam = "ENABLED"` — that is when an AP earns its keep.

## Migration sequence

Each phase is one PR (or a small PR set) and is independently revertable.

| Phase                                        | Scope                                                   | Risk                                                                                                                                                                                                                  |
| -------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 — fail2ban + NET_ADMIN                     | Docker + Terraform ECS task defs                        | Low. No-op on behaviour; reduces capabilities.                                                                                                                                                                        |
| 2 — Runtime posture (caps, no-new-privs, init) | Terraform ECS task defs                                 | Medium for the caps/no-new-privs/init posture (all tiers). ROFS is deferred for the mail tiers — they regenerate `/etc/mail` + `/etc/opendkim` at runtime; only the monitoring tier gets ROFS in 0.10.x. See Phase 2 for the option 1/2/3 tradeoff.                                                                          |
| 3 — Image digest pinning + ECR scan-on-push  | Dockerfiles, ECR module, deploy script, Renovate config | Medium. Build cadence changes; expect some early scan-on-push noise from the AL2023 base.                                                                                                                             |
| 4 — Dovecot plaintext-off + throttling       | Docker dovecot configs + entrypoint                     | Medium. Auth path change; test with React webmail and Apple clients before promotion.                                                                                                                                 |
| 5 — Sendmail/OpenDKIM hardening              | Docker .mc templates + generate-config.sh               | Low to medium. `confMAX_MESSAGE_SIZE` change is the user-visible one (50 MB cap); document in release notes. OpenDKIM scope change is invisible to clients.                                                            |
| 6 — EFS transit encryption on IMAP           | Terraform EFS + ECS                                     | Low. Mailstore data path is unchanged; only the wire is now TLS. Brief outage on the access-point creation roll-forward (one task-set replacement).                                                                  |

Each phase runs the full dev → stage → prod sequence per the standard branching rules. Phases 2 and 4 are the ones to slow-roll; the rest can move as quickly as CI feedback supports.

## Rollback

- Phase 1: revert PR; the fail2ban code returns commented-out. NET_ADMIN can be re-added by an Edit if a future need arises.
- Phase 2: per-tier `readonlyRootFilesystem = false` and remove `dockerSecurityOptions`. ECS rolls back on next apply.
- Phase 3: SSM image-tag pattern can fall back to the old `<repo>:sha-<8>` shape; ECR scan-on-push can be disabled by Terraform flag. Digest-pinned `FROM` lines can revert to tags.
- Phase 4: `disable_plaintext_auth = no` returns. `auth_failure_delay = 0`. Throttling settings removed.
- Phase 5: revert the .mc edits. Old maps are still valid; sendmail recompiles on next entrypoint.
- Phase 6: revert the ECS task-def change. The access point can stay (cheap) or be destroyed in a follow-up.

## CI changes

- [`.github/workflows/app.yml`](../../.github/workflows/app.yml)'s `docker` matrix gains a Trivy scan step that runs `trivy image --severity HIGH,CRITICAL --exit-code 1` (with a soft-fail-then-baseline rollout matching the [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md) cadence).
- The `deploy-ecs-service.sh` script gains digest extraction from buildx and writes the digest (not the tag) into the `/cabal/deployed_image_tag` SSM parameter.
- Renovate (or Dependabot) gains a `docker:` config block that auto-PRs base-image and third-party-image digest bumps.
- A nightly scheduled workflow (`.github/workflows/image-scan.yml`, new) re-runs Trivy against the currently-deployed digests and uploads SARIF to GitHub Code Scanning.

## Acceptance

- `aws ecs describe-task-definition` shows `linuxParameters.capabilities.drop = ["ALL"]` and `no-new-privileges:true` for all three mail tiers in stage and prod. `readOnlyRootFilesystem = true` shows on the monitoring tier; the mail tiers carry it only if option 2 or 3 from Phase 2 lands.
- A trial `docker run` of the imap image with `--cap-add NET_ADMIN` removed boots end-to-end with no errors; supervisord, sendmail, dovecot, and opendkim are all in the "running" state at startup. (A `--read-only` variant of this trial is the feasibility gate for the Phase 2 option 2/3 ROFS work, not a 0.10.x acceptance criterion for the mail tiers.)
- ECR scan-on-push has zero HIGH/CRITICAL findings against the latest build for each tier, or a baseline file with one-line justifications mirroring the IaC-baseline pattern.
- An attacker connecting to the IMAP service over a plaintext (non-TLS) path inside the VPC (simulating an NLB bypass) is refused at auth: `BAD [PRIVACYREQUIRED] Plaintext authentication disallowed on non-secure (SSL/TLS) connections.`
- An OpenDKIM debug log entry (toggled via env var for the verification window) shows `external host 10.x.x.x is not internal` when a message is fed via a non-loopback path.
- `sendmail -bt` reports `MaxMessageSize = 52428800`. A test message larger than 50 MB receives a 552 from sendmail.
- The mailstore EFS access point exists; `aws efs describe-mount-targets` shows the IMAP task connecting with `transit_encryption=true`.
- A new HIGH-severity CVE in `amazonlinux:2023` produces a Renovate PR within 24 hours of publication and a nightly Trivy SARIF entry on the Security tab.

## Open questions

- **Capabilities for sendmail privilege drop.** Sendmail historically requires `setuid`/`setgid` at startup to bind port 25 as root then drop. With `no-new-privileges`, the drop still works; with `cap_drop: ALL` and no `add`, port-binding may fail. Verify in dev: if `CAP_NET_BIND_SERVICE` is required, add it back per-tier.
- **TLS 1.3 floor.** Re-evaluate at the end of Phase 4. If client compatibility data shows no TLS-1.2-only IMAP clients, raise the floor.
- **`amazonlinux:2023` vs `chainguard/wolfi-base`.** Chainguard's distroless-adjacent images would shrink the attack surface significantly. The sendmail+dovecot stack does not exist there out of the box — porting is a separate plan. Mention but defer.
- **Per-recipient send-rate limiting in submission.** Dovecot's submission-login throttling is auth-side; per-recipient throttling belongs upstream (in `/send` Lambda — captured in [`application-surface-hardening-plan.md`](./application-surface-hardening-plan.md) Phase 5 follow-up).
- **fail2ban replacement at the NLB.** If we ever observe brute-force traffic, the right answer is an NLB-side rate limit + WAF, not a per-container fail2ban. Out of scope here; flag for the identity/IAM plan.

## Out of scope for 0.10.x

- Multi-container task definitions (one process per container).
- Distroless or minimal base images.
- AppArmor/seccomp profiles.
- Fargate migration.
- Sendmail replacement (separate plan: [`docs/unreleased/sendmail-replacement.md`](../unreleased/sendmail-replacement.md)).
- NLB proxy-protocol enablement and per-IP rate limiting.
