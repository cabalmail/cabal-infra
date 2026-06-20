# Compatibility and versioning

Cabalmail follows [Semantic Versioning 2.0.0](https://semver.org/). This document
defines what that means in practice: which parts of the system are a stable,
versioned contract, what counts as a breaking change, and how deprecations and
upgrades are handled.

These guarantees take effect at **1.0.0**. Releases in the `0.x` series carried
no compatibility guarantees - anything could change between them.

## Who this is for

Cabalmail is a self-hosted system rather than a library or a hosted service, so
"compatibility" is a promise to three audiences:

- **Client developers** building against the HTTP API (the React, Apple, and
  Android clients all do).
- **Operators** who deploy and upgrade their own instance.
- **End users** whose mailboxes and addresses must survive upgrades.

## Versioning rules

Given a version `MAJOR.MINOR.PATCH`:

- **PATCH** - backward-compatible bug fixes only.
- **MINOR** - backward-compatible additions: new API endpoints or response
  fields, new optional configuration, new features. Existing behavior is
  unchanged.
- **MAJOR** - any incompatible change to a stable surface (below), or an upgrade
  that requires a manual or destructive migration.

Version numbers only increase and are never reused. Pre-release identifiers (for
example `1.0.0-rc.1`) may be used for testing and carry no stability guarantee.

## Stable surfaces

From 1.0.0, the following are the public contract. A backward-incompatible change
to any of them requires a major version bump.

### 1. HTTP API

The API Gateway + Lambda endpoints consumed by the clients:

- The set of endpoints and their request and response shapes.
- The JSON response envelope and the meaning and type of documented fields.
- Status-code semantics, including the `503` planned-maintenance contract
  (`Retry-After`, `{"status": "maintenance", ...}`).
- The request path convention (folder paths use `/` in requests and are
  normalized internally).

Breaking: removing or renaming an endpoint or a response field, changing a
field's type or meaning, making a previously optional request parameter
required, or changing the authentication scheme.

Non-breaking (minor): adding an endpoint, adding a response field, or accepting a
new optional parameter. **Clients must ignore unknown fields and tolerate new
endpoints and values** so that these additions stay non-breaking.

### 2. Authentication

- Amazon Cognito sign-up, confirmation, and login.
- A bearer JWT presented in the `Authorization` header.
- One Cognito user maps to one mailbox, provisioned automatically on
  confirmation.

Breaking: changing the authentication mechanism, the token format, or how the
token is presented.

### 3. Mail service interface

- The IMAP, inbound SMTP, and submission endpoints, their ports (993, 25, 587,
  465), and their TLS requirements.
- The addressing model: mail is hosted on subdomains only (the apex carries no
  addressing), and addresses follow the per-purpose create/revoke lifecycle.
- DKIM signing of outbound mail.

These largely track the relevant email RFCs; the promise is that the endpoints,
ports, and addressing model remain compatible within a major version.

### 4. Operator configuration

- The documented `TF_VAR_*` input variables and their meaning and defaults.
- The branch-to-environment mapping (`main`/`stage`/`development`) and the deploy
  model.

Breaking: removing or renaming a documented variable, or changing a variable's
meaning or default such that an existing deployment's behavior changes or manual
intervention is required.

### 5. Data durability and upgrade safety

The strongest guarantee. Within a major version:

- Applying a newer release to an existing deployment through the normal pipeline
  preserves all user data - mailboxes on EFS and addresses in DynamoDB - and
  requires no undocumented manual steps.
- Expected operational blips are not breaking changes (for example, the brief
  single-task IMAP window during an image roll, surfaced to clients as the
  maintenance `503`).

A major version may require a migration; when it does, the steps are documented
in that release's notes.

## Internal surfaces (not under the promise)

These may change in any release, including a patch. Do not build external
integrations on them:

- Lambda internals, including the shared helper module and function packaging.
- Container image internals: supervisord, sendmail templates, entrypoint and
  reconfiguration scripts, and the master-user IMAP login mechanism and its
  username format.
- ECS task definitions, revision markers, and service topology.
- S3 cache key layout, SSM parameter names, and EFS internal directory
  conventions beyond the guarantee that your mail persists.
- The admin web bundle's internals and its runtime `config.js` schema (the app
  and its config are versioned together).
- CI/CD workflows, the release and changelog tooling, and security-scanner
  configuration.
- Image tags, the build process, and bundled dependency versions.

## Deprecation policy

A stable element is removed only after a deprecation period:

1. It is announced as deprecated in a **minor** release, via a `Deprecated`
   changelog entry and a note in the relevant docs.
2. It keeps working for at least the remainder of the current major series.
3. It is removed no earlier than the next **major** release.

## Consumer responsibilities

Compatibility is a two-way contract. To stay compatible across minor and patch
upgrades:

- **API clients** must ignore unknown JSON fields, tolerate new endpoints and
  values, and never depend on internal surfaces.
- **Operators** should read the changelog's `Changed`, `Deprecated`, and
  `Removed` sections and the release notes before upgrading, especially across a
  major.

## Security exception

A fix for a serious security issue may require a change that is technically
breaking. Such a change can ship in a minor or patch release when withholding it
would leave deployments exposed. It is always called out in the `Security`
changelog section and the release notes, with any action an operator must take.
