# Private IMAP and SMTP-Submission Plan

## Context

Today the NLB in [`terraform/infra/modules/elb`](../../terraform/infra/modules/elb) exposes three mail tiers to the public internet:

| Listener | Tier     | Purpose                                  | Public?           |
| -------- | -------- | ---------------------------------------- | ----------------- |
| 25/tcp   | smtp-in  | Inbound MTA-to-MTA relay                 | yes (must remain) |
| 465/tcp  | smtp-out | Submission (implicit TLS)                | yes (closing)     |
| 587/tcp  | smtp-out | Submission (STARTTLS)                    | yes (closing)     |
| 143/tcp  | imap     | Cleartext IMAP (per `local.tiers`)       | yes (closing)     |
| 993/tls  | imap     | IMAPS, ACM-terminated                    | yes (closing)     |

Every first-party Cabalmail client now reaches IMAP and SMTP submission through the Lambda API, not directly:

- The React webmail at [`react/admin`](../../react/admin) has always called Lambda endpoints. Out of the box it never opens a raw IMAP socket.
- The Apple clients in [`apple/`](../../apple) route through [`ApiBackedImapClient`](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift). The hand-rolled `LiveImapClient` still compiles and has tests, but production wiring in `CabalmailClient.live(...)` uses the API-backed path. See [`issue #371`](https://github.com/cabalmail/cabal-infra/issues/371) for the rationale.

The only consumers of the public 993/465/587 listeners are therefore *third-party* IMAP/SMTP clients (Apple Mail.app, iOS Mail, Outlook, K-9, Thunderbird, etc.). The product decision recorded by this plan is that we are no longer going to support them: Cabalmail users use a native Cabalmail client, and the IMAP/submission surface stops being a public attack surface.

This is a posture change, not a feature: the Lambda API surface stays exactly the same; only the wire path between Lambdas and the mail containers moves inside the VPC.

The roadmap parks this under `0.10.x` because the per-phase changes are individually small and reversible. The risky moments are the cutover of the NLB listeners (Phase 4) and the moment the Lambdas start depending on VPC connectivity (Phase 3); each is staged so it can be rolled back by reverting a single PR.

## Goals

- Public ingress to IMAP (143, 993) and SMTP submission (465, 587) is closed at the NLB *and* at the security group. A scan of the NLB's public ENIs returns no listener on those ports.
- Public DNS no longer resolves `imap.<control_domain>` or `smtp-out.<control_domain>`. Inside the VPC, both names continue to resolve via the private Route 53 zone *or* via Cloud Map private DNS.
- Every Lambda that reaches IMAP, SMTP submission, S3, DynamoDB, SSM, SNS, Cognito, or CloudWatch Logs runs in private subnets (`vpc_config { subnet_ids = var.private_subnet_ids, ... }`).
- High-volume / per-request AWS API traffic from those Lambdas (S3, DynamoDB, SSM, CloudWatch Logs, Cognito, SNS) goes through VPC endpoints, not the NAT instance. Low-volume / global-service traffic (Route 53) keeps egressing through NAT.
- Lambda code stops trusting client-supplied `body['host']` / `body['smtp_host']` for IMAP/SMTP target selection. The container host is pinned server-side, derived from configuration (env var or Cloud Map name).
- `smtp-in` remains public on port 25. The plan does not change anything about how the rest of the internet delivers mail to Cabalmail.
- Each phase is independently revertable. A failed Phase N is rolled back without touching Phases 1..N-1.

## Non-goals

- Re-architecting the mail tiers themselves. Dovecot, Sendmail, OpenDKIM, the supervisord layout, the EFS mailstore, the SNS/SQS reconfiguration path — all unchanged.
- Replacing the NLB with an ALB, or fronting Lambda-to-IMAP traffic with a service mesh. The Cloud Map private namespace plus existing security-group rules are sufficient.
- Migrating to AWS PrivateLink endpoint services for the mail tiers. This is a single-tenant deployment; the VPC's own internal addressing is enough.
- Removing the public 25 listener on `smtp-in`. Inbound MX cannot move behind a private endpoint without breaking the basic premise of being a mail server.
- Wiring SES, SES SMTP, or any other AWS-managed submission relay. Out of scope.
- Adding IPv6 ingress, dual-stack VPC endpoints, or any other v6 work. Tracked separately.
- Deleting the unused `LiveImapClient` Swift code path. Leaving it in place keeps the test coverage intact and is one less moving part during the rollout; a separate PR can prune it after the dust settles.
- Forcing a minimum native-client version. The Apple and React clients already use the API; once IMAP/submission go private, *third-party* clients stop working but first-party clients are unaffected. We do not need a client-side flag day.

## Current state (audit)

### Lambda inventory

Two groups, organized by what each function touches today:

**Lambdas that open IMAP sessions** (`grep -l IMAPClient lambda/api/*/function.py`):

`delete_folder`, `folder_status`, `list_envelopes`, `list_folders`, `list_messages`, `move_messages`, `new_folder`, `process_dmarc`, `search`, `send`, `set_flag`, `subscribe_folder`, `unsubscribe_folder`. Thirteen functions.

Of these, only [`send`](../../lambda/api/send/function.py) also opens an SMTP submission session (`smtplib.SMTP_SSL(smtp_host)`); the rest are IMAP-only.

[`process_dmarc`](../../lambda/api/process_dmarc/function.py) is fired by EventBridge Scheduler every six hours, not by API Gateway. It pulls DMARC aggregate reports from the `dmarc@` mailbox over IMAP. Same VPC requirement, different invocation path.

**Lambdas that touch private AWS data planes but not IMAP/SMTP**:

Every other entry under [`lambda/api/`](../../lambda/api) plus [`lambda/counter/assign_osid`](../../lambda/counter/assign_osid). Per the policy in the request — "Lambdas that require access to private resources (IMAP, SMTP submission, S3, etc.) should be VPC-attached" — these qualify because they all read/write S3 (cache bucket, presigned URLs) or DynamoDB (addresses, preferences, domain access). The IAM policy in [`modules/app/modules/call/lambda.tf`](../../terraform/infra/modules/app/modules/call/lambda.tf) already grants every API Lambda the full S3+DynamoDB+SNS+Cognito surface, so the scope here is "all 40+ API Lambdas," not a subset.

**Lambdas that are pure control-plane and can stay on Lambda-managed networking**:

- [`certbot-renewal`](../../lambda/certbot-renewal): uses `certbot --dns-route53`. Touches only ACM, Route 53, ECS, and SSM. No data-plane resource. Could move into the VPC for uniformity but does not have to.
- [`alert_sink`](../../lambda/api/alert_sink): a Function-URL'd webhook receiver for Alertmanager. Talks to SNS or SSM only. Not data-plane.
- [`backup_heartbeat`](../../lambda/api/backup_heartbeat): scheduled, talks to Healthchecks via internet and to SSM. Already a candidate for VPC placement next to `healthchecks_iac` if we want it reaching the in-VPC Healthchecks instance, but that's a separate decision (it's currently fine on the public path).
- [`check_invite`](../../lambda/api/), [`confirm_user`](../../lambda/api/): pre-/post-Cognito triggers — could stay public-side.

The full per-Lambda IAM picture lives in [`terraform/infra/modules/app/modules/call/lambda.tf`](../../terraform/infra/modules/app/modules/call/lambda.tf:45-141); the existing policy is uniform across every API Lambda, so we do not have to reason per-function about the IAM surface.

### Existing VPC-attached Lambda precedent

[`healthchecks_iac`](../../terraform/infra/modules/monitoring/healthchecks_iac.tf) is already VPC-attached. It uses:

- `aws_iam_role_policy_attachment "...vpc"` with `AWSLambdaVPCAccessExecutionRole`.
- A dedicated security group with explicit egress: SG-to-SG for the Healthchecks task on 8000, UDP/53 to the VPC CIDR for Route 53 Resolver, and TCP/443 to `0.0.0.0/0` for AWS API endpoints (since there are no VPC endpoints in the stack today).
- `vpc_config { subnet_ids = var.private_subnet_ids, security_group_ids = [...] }`.

The 443-to-anywhere rule is the only piece that should change once VPC endpoints exist — once SSM, Logs, etc. have interface endpoints, the SG can scope its 443 egress to the endpoints' SG. Reusing this pattern for the API fleet keeps the topology consistent.

### Network topology

From [`terraform/infra/modules/vpc`](../../terraform/infra/modules/vpc):

- One VPC. Public and private subnets, one of each per AZ, derived by `cidrsubnet(var.cidr_block, local.bit_offset, ...)`.
- A single NAT (instance, by default; gateway optional). Private route tables point `0.0.0.0/0` at it. Quiesce removes that route.
- A private Route 53 zone for `<control_domain>`; private records for `smtp-out` and `smtp-in` exist (mirrored from the public NLB aliases). `imap` is *intentionally absent* from the private zone — the comment in [`modules/elb/dns.tf:24-39`](../../terraform/infra/modules/elb/dns.tf) explains: the NLB's port-25 listener forwards to smtp-in, not imap, so an NLB alias for `imap` here would misdirect mail delivery. Internal IMAP access uses Cloud Map (`imap.cabal.internal`).
- A Cloud Map private DNS namespace `cabal.internal` is registered for the IMAP service ([`modules/ecs/service_discovery.tf`](../../terraform/infra/modules/ecs/service_discovery.tf)). There is no Cloud Map registration for `smtp-out` yet.
- No `aws_vpc_endpoint` resources exist anywhere in the stack. Lambda-to-AWS traffic from the VPC today goes over NAT.

### Listener / DNS shape after the change (target)

| Listener | Tier     | Public? | Notes                                          |
| -------- | -------- | ------- | ---------------------------------------------- |
| 25/tcp   | smtp-in  | yes     | Unchanged                                      |
| 465/tcp  | smtp-out | **no**  | Listener removed; Cloud Map name + SG-to-SG only |
| 587/tcp  | smtp-out | **no**  | Listener removed                               |
| 993/tls  | imap     | **no**  | Listener removed (TLS termination moves to Dovecot or to an internal NLB; see decision point below) |

Public DNS:
- `imap.<control_domain>` A record: **deleted**.
- `smtp-out.<control_domain>` A record: **deleted**.
- `smtp-in.<control_domain>` A record: unchanged.
- The IMAPS / submission SRV records in [`modules/elb/dns.tf:41-70`](../../terraform/infra/modules/elb/dns.tf) (`_imaps._tcp`, `_submission._tcp`) become misleading once the targets vanish. Either delete the SRV records or repoint the port to `0` with host `.` — matching the "absent" convention already used by `_imap._tcp` / `_pop3._tcp` / `_pop3s._tcp` in the same map. The latter is cleaner because RFC 6186 specifically uses `0 1 0 .` to advertise that a service is absent — clients reading the autodiscovery records get a definitive answer rather than NXDOMAIN.

Private DNS / service discovery:
- `imap.cabal.internal` (Cloud Map) — unchanged.
- `smtp-out.cabal.internal` (Cloud Map) — **new** registration for the submission container.
- The private Route 53 record `smtp-out.<control_domain>` — keep for backwards compatibility with the existing Sendmail config, or repoint at Cloud Map. Decide in Phase 4.

### Decision: where does IMAPS TLS terminate?

Today the NLB terminates TLS for 993 (the only `protocol = "TLS"` listener; 465/587 are TCP passthrough and Dovecot/Sendmail terminate TLS in-container). Two options for the internalized world:

1. **Move TLS termination into Dovecot.** The certbot-renewal Lambda already produces Let's Encrypt certs for the container. Dovecot serves IMAPS on 993 directly to its callers. The NLB IMAP listener is deleted outright; no internal NLB is needed for IMAP.
2. **Keep an internal NLB with the ACM-terminated IMAPS listener.** Create a *second* NLB with `internal = true` in the private subnets and put the 993 (TLS) and 465/587 (TCP) listeners on it. The public NLB keeps only port 25.

Option 1 is structurally simpler: zero NLB listeners for IMAP/submission, one less load balancer to reason about, no ACM cert churn between NLB and container. Option 2 keeps the ACM-managed cert lifecycle in place and matches the existing shape. **Recommendation: Option 1.** The cert lifecycle inside Dovecot is already battle-tested (certbot-renewal writes the cert into the container's EFS volume and rolls the service via `forceNewDeployment`), and the NLB TLS terminator was useful primarily for offloading TLS from third-party clients we are no longer supporting. Phase 4 includes the listener cleanup; Phase 5 retires the NLB target groups and (if Option 1) drops the IMAP-on-NLB plumbing entirely. Phase 4 is also the moment we verify Dovecot terminates 993 the way we expect — if it doesn't, we fall back to Option 2 before merging.

### VPC endpoint inventory

| Service          | Endpoint type | Mandatory? | Volume                                    | Justification                              |
| ---------------- | ------------- | ---------- | ----------------------------------------- | ------------------------------------------ |
| S3               | Gateway       | yes        | high (per-message caching, attachments)   | Free (route table entry); huge NAT savings |
| DynamoDB         | Gateway       | yes        | high (every address/preferences lookup)   | Free; ditto                                |
| SSM Messages     | Interface     | yes        | low-but-hot (one `get_parameter` per cold start, then cached) | Lambdas read `/cabal/master_password` and other SSM params at module-load time |
| SSM              | Interface     | yes        | same                                       | "SSM" needs both `ssm` and `ssmmessages` endpoints for full coverage; in this case just `com.amazonaws.<region>.ssm` is enough since the Lambdas only do `get_parameter` / `put_parameter` |
| CloudWatch Logs  | Interface     | yes        | high (every Lambda execution writes logs) | Logs would otherwise hammer NAT            |
| SNS              | Interface     | recommended | medium (address-change publishes)         | Quieter than logs but lives in the hot path for `new`/`revoke` |
| Cognito-IDP      | Interface     | recommended | low (admin endpoints only)                | Available in all regions Cabalmail runs in; avoids NAT for admin paths |
| ECS              | Interface     | optional   | very low (only `assign_osid` triggers `update_service`) | Single Lambda; can stay on NAT |
| Route 53 (data plane) | Interface | n/a        | n/a                                       | No public Resolver/data-plane endpoint exists; lookups stay on VPC Resolver (which is in-VPC anyway) |
| Route 53 (API)   | n/a           | not available | n/a                                    | Lambdas that write Route 53 records (`new`, `revoke`, `new_address_admin`, `repair_dns_record`, `certbot-renewal`) must keep NAT egress |
| STS              | Interface     | yes-if     | low                                       | `boto3` resolves credentials via STS in some auth chains; without an endpoint they fall back to NAT, which works but means a cold-start STS call goes outbound |

Three AZs × five interface endpoints (SSM + Logs + SNS + Cognito + STS) ≈ five ENIs per AZ × $7.30/month each ≈ $110/month. The two gateway endpoints (S3, DDB) are free. The bill scales with environments, so the dev environment should drop interface endpoints while quiesced.

Out of scope for the endpoint policy: VPC endpoint **policies**. The default "*" policy is fine for the first ship; tightening to "this VPC only" / "these IAM principals only" is a follow-on.

### Latent issues that surface during this work

1. **Client-supplied `body['host']` / `body['smtp_host']`.** Every Lambda that calls `get_imap_client` reads the IMAP hostname out of the API request body and passes it to `IMAPClient(host=...)`. Today this is bounded by the fact that the IMAP host's master-user credential is in SSM and the public DNS resolves only to the Cabalmail NLB. Once the IMAP target is internal, this becomes ambient trust: a malicious or misbehaving client could in principle point the Lambda at *any* hostname the Lambda can resolve. The fix is to pin the target server-side in an env var (`IMAP_HOST=imap.cabal.internal`, `SMTP_HOST=smtp-out.cabal.internal`) and stop reading those fields from the request. The `body['host']` is also used to derive the cache bucket name (`bucket = body['host'].replace('imap', 'cache')` in [`send/function.py:37`](../../lambda/api/send/function.py)); that derivation can move to an env var too. Folding this into the privatization is natural and removes a footgun that wasn't worth its own ticket.

2. **`LiveImapClient` in CabalmailKit.** Compiles and tested but unused in production. Once IMAPS is private, even a future operator who wires up `LiveImapClient` for diagnostics from outside the VPC will fail. Document that it's now also a build-time-only artifact; deletion is a follow-up.

3. **Healthchecks/Kuma probes of the public IMAP/submission ports.** The Phase 1 monitor set probes `smtp-in.<control>:25` and the API endpoint, not 993/465/587. Worth re-checking when Phase 4 lands so we're not staring at a flat-lined-but-not-broken IMAP monitor.

4. **MX-then-A check on the IMAP container's `check_mail` rule.** This is on the inbound-delivery path (smtp-in -> sendmail -> local delivery -> IMAP storage), not the public IMAP listener — unaffected. Worth recording so the reader does not assume it.

5. **Documentation that points users at standard mail clients.** [`docs/mua_setup.md`](../../docs/mua_setup.md) explains how to wire up Apple Mail / Thunderbird against `imap.<control_domain>:993`. After Phase 4 that document is wrong; it gets a clear "this guide is historical; use a native Cabalmail client" banner in Phase 6.

## Phased rollout

Each phase is a single PR (or a tightly coupled pair). Phases are ordered cheap/risk-low first; later phases assume earlier ones.

**Phase 1 — Pin IMAP/SMTP targets server-side.** Stop trusting `body['host']` / `body['smtp_host']`. The [`modules/app/modules/call/`](../../terraform/infra/modules/app/modules/call) Lambda module adds two env vars (`IMAP_HOST`, `SMTP_HOST`) populated by Terraform from the control domain. [`_shared/helper.py`](../../lambda/api/_shared/helper.py) gains `IMAP_HOST = os.environ.get('IMAP_HOST', ...)` and the per-Lambda call sites stop reading `body['host']`. The cache-bucket derivation moves to an env var too. The wire contract from clients keeps accepting `host` / `smtp_host` for backwards compatibility but the Lambda ignores them. Both the React client and the Apple `ApiBackedImapClient` keep sending the field for now; a follow-up trims it. No infrastructure change. Ships through `stage` -> `main`.

**Phase 2 — VPC endpoints.** Add `aws_vpc_endpoint` resources for S3 and DynamoDB (gateway) and for SSM, CloudWatch Logs, SNS, Cognito-IDP, and STS (interface). Interface endpoints get a dedicated SG that accepts 443/tcp from the VPC CIDR. Gateway endpoints associate with the private route tables. Endpoint policies default to `"*"`. No Lambdas use the endpoints yet — they keep going over NAT — but the endpoints exist so Phase 3 doesn't have to wait. Direct-to-prod is *not* allowed here: this is an additive infra change but it touches the data-plane reachability surface for Lambdas in private subnets, so route through `stage`. The dev environment also gets the endpoints applied when it's unquiesced for the Phase 3 validation pass.

**Phase 3 — VPC-attach the API Lambda fleet.** The [`call`](../../terraform/infra/modules/app/modules/call) module is the right place: every API Lambda runs through this submodule, so adding `vpc_config` once flips them all. Mirror the [`healthchecks_iac`](../../terraform/infra/modules/monitoring/healthchecks_iac.tf) pattern: dedicated SG per call, the `AWSLambdaVPCAccessExecutionRole` attachment, `subnet_ids = var.private_subnet_ids`, security-group rules that allow:
  - 443/tcp to the interface-endpoint SG
  - 53/udp to the VPC CIDR (Route 53 Resolver + Cloud Map)
  - 993/tcp to the IMAP tier SG (added in Phase 3.5)
  - 465/tcp and 587/tcp to the smtp-out tier SG (added in Phase 3.5)
  - 443/tcp to `0.0.0.0/0` for the few remaining NAT-only AWS APIs (Route 53 API mainly)
Lambdas are not yet directed at internal IMAP/SMTP targets — the public NLB still works, and the env vars from Phase 1 still point at `imap.<control_domain>` which resolves publicly. The Lambdas now have *the option* of resolving Cloud Map names but don't depend on them. This phase exists so the cutover in Phase 4 is small. **Risk:** cold-start latency. The Hyperplane ENI work landed years ago so the penalty is ~1s, but `process_dmarc` (a 6-hourly scheduled job) is the canary — verify it still completes inside its 120s timeout once VPC-attached. Validate in `development` first.

**Phase 3.5 — `smtp-out.cabal.internal` Cloud Map registration.** Mirror the existing `imap` registration in [`modules/ecs/service_discovery.tf`](../../terraform/infra/modules/ecs/service_discovery.tf) for the smtp-out service. The smtp-out task definition's service registration gets a `registry_arn`. Verify that `smtp-out.cabal.internal:465` is reachable from a test invocation of the VPC-attached `send` Lambda. No public-facing impact.

**Phase 4 — Cut the listeners and DNS.** Three changes in one PR:
  1. In [`modules/elb`](../../terraform/infra/modules/elb), delete `aws_lb_listener.imap`, `aws_lb_listener.submission`, `aws_lb_listener.starttls`. The relay listener (port 25) stays.
  2. In [`modules/ecs/locals.tf`](../../terraform/infra/modules/ecs/locals.tf), remove `143` and `993` from `imap.public_ports`, remove `465` and `587` from `smtp-out.public_ports`. The ECS tier security groups stop opening those ports from `0.0.0.0/0`. (`smtp-in.public_ports = [25]` stays.) Add `private_ports = [993]` for the imap tier (so the API Lambdas' SG can reach it via SG-to-SG; the existing `private_ingress` rule allows VPC CIDR, which already covers Lambda ENIs in private subnets — explicit SG-to-SG is the tighter form and goes in Phase 3 SG rules).
  3. In [`modules/elb/dns.tf`](../../terraform/infra/modules/elb/dns.tf), remove `imap` and `smtp-out` from the `for_each` set of `aws_route53_record.cname` (deleting the public A records). Update the `_imaps._tcp` and `_submission._tcp` SRV records to `0 1 0 .` so autodiscoverers get a definitive "absent" answer. Update the env vars from Phase 1 to point at the internal Cloud Map names (`imap.cabal.internal`, `smtp-out.cabal.internal`).
  Critically: this is the only phase that *removes* public ingress. Verify in stage first; only promote to prod after a watching-window of at least 24h and after explicitly checking that the React webmail and the Apple client both function. Rollback is "revert the PR" — listeners and DNS records come back as they were.

**Phase 5 — NLB cleanup.** With the IMAPS and submission listeners gone, the ACM cert resource for the IMAP listener (and the IMAP target group, if Option 1 was chosen) is orphaned. Delete the dead Terraform: `aws_lb_target_group.tier["imap"]`, `aws_lb_target_group.tier["submission"]`, `aws_lb_target_group.tier["starttls"]`, and the IMAP/submission entries in [`locals.tf:target_groups`](../../terraform/infra/modules/ecs/locals.tf:49-54). The NLB itself stays (it still hosts the port-25 listener). If Option 2 was chosen (internal NLB), this phase instead promotes the staged internal NLB to be the canonical one.

**Phase 6 — Docs and follow-ups.**
  - Update [`docs/mua_setup.md`](../../docs/mua_setup.md) with a "historical, do not follow" banner.
  - Update [`docs/setup.md`](../../docs/setup.md) and [`docs/operations.md`](../../docs/operations.md) to mention the new break-glass path: SSM port-forward through the ECS instance to reach Dovecot at `localhost:993` for diagnostic IMAP access.
  - Note the `LiveImapClient` deprecation in [`apple/`](../../apple) (don't delete yet; a clean removal is its own PR).
  - Tighten interface endpoint policies to "this VPC only" (or to specific IAM principals) once stable.
  - Quiesce: extend [`docs/quiesce.md`](../../docs/quiesce.md) to cover removing the interface endpoints when an environment is parked. The gateway endpoints are free, leave them.

## Risks and trade-offs

- **Cold-start latency.** Phase 3 puts every API Lambda in a private subnet behind a Hyperplane ENI. The cold-start penalty is small (~1s) but real. Watch p95 latency on `list_envelopes` / `list_messages` over the first day. If it's noticeable, provisioned concurrency on the two or three hot endpoints is the standard mitigation. Out of scope for the rollout itself.

- **`process_dmarc` is a canary.** It's a 6-hourly scheduled Lambda with the same dependency surface as the API Lambdas, so it surfaces VPC issues without paging an operator. Watch its CloudWatch logs after Phase 3.

- **Break-glass dependency on SSM Session Manager.** With public IMAP gone, the only way to inspect Dovecot from outside the VPC is `aws ssm start-session ...` port-forwarding to the ECS instance. The ECS instance role already has the SSM permissions (`AmazonSSMManagedInstanceCore`). The risk is that during an incident where SSM itself is degraded, there's no fallback. Mitigation: documented runbook and an awareness that the operator's AWS access has to be working. We accept this as the consequence of the design.

- **VPC endpoint cost in non-prod.** Five interface endpoints × three AZs × $7.30/mo ≈ $110/mo per environment. Significant for the dev environment unless quiesce removes the endpoints. The Phase 6 quiesce work covers this; in the interim, the dev environment runs warm during the Phase 3 validation pass and accepts the bill for that window.

- **`body['host']` change has a deployment ordering wrinkle.** Phase 1 makes the Lambda ignore `body['host']` but the clients still send it. If a future client uses a non-default host value for testing, it'll be silently overridden. Document the change; consider returning a warning header for one release.

- **Cloud Map dependency in the Lambda hot path.** Once Phase 4 lands, every API call resolves `imap.cabal.internal` or `smtp-out.cabal.internal` through the Route 53 Resolver. The Resolver is highly available but adds one round trip on cold IMAP-client construction. Existing connection-pool work in [`docs/0.10.x/large-mailbox-hardening-plan.md`](./large-mailbox-hardening-plan.md) (Phase 7, "IMAP session pooling in the Lambda") cancels this overhead once it lands. The two plans complement each other but are independently shippable.

- **Public DNS deletion is hard to roll back precisely.** Deleting `imap.<control_domain>` and `smtp-out.<control_domain>` is reversible by reverting Phase 4, but DNS caches mean clients may briefly resolve stale entries. Coordinate the cutover with low traffic; no flag-day notification is required (no first-party client uses these records).

- **Direct-to-prod eligibility.** Phase 1 (code-only, no contract change) and Phase 6 (docs) are candidates for direct-to-prod under the [project rules](../../CLAUDE.md#direct-to-prod-scaffolding). Phases 2, 3, 3.5, 4, and 5 touch IAM / data-plane / security surface and route through `stage` -> `main`.

- **Forward compatibility with the Android client roadmap.** The [Android client](../../docs/2.0.x) is planned as another first-party native client; it will also hit the Lambda API rather than IMAP directly. Privatizing IMAP/submission does not constrain that work.

- **Failure to terminate TLS in Dovecot at 993.** The Option 1 / Option 2 decision in Phase 4 hinges on Dovecot's cert wiring being correct. If the certbot-renewal Lambda's existing rollout doesn't put the cert where Dovecot expects, we fall back to Option 2 (internal NLB) without altering any of the earlier phases.
