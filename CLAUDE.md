# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cabalmail is a self-hosted email system running on AWS. This repository contains all infrastructure, server configuration, and the admin web app. The system provides three mail tiers — IMAP (mailbox access), SMTP-IN (inbound relay), and SMTP-OUT (outbound submission with DKIM signing) — backed by Cognito authentication, DynamoDB address storage, and EFS-based mailstores.

The mail tiers run as Docker containers on ECS (EC2 launch type). See `docs/0.4.0/containerization-plan.md` for the migration plan from the previous Chef/EC2 architecture.

## Repository Structure

```
react/admin/        React frontend (email client + address/folder management)
lambda/api/         AWS Lambda functions behind API Gateway (Python)
lambda/counter/     Cognito post-confirmation trigger (Python)
lambda/certbot-renewal/  Let's Encrypt certificate renewal Lambda
terraform/dns/      Bootstrap stack: Route 53 zone for the control domain
terraform/infra/    Main stack: VPC, ECS, ELB, Cognito, DynamoDB, CloudFront, Lambda, etc.
docker/             Container images for mail tiers (imap, smtp-in, smtp-out)
docs/               Architecture docs, migration plans, setup guides
.github/workflows/  CI/CD pipelines for all components
.github/scripts/    Shared build/deploy helper scripts
```

## Build/Lint/Test Commands

### React App (`react/admin`)
- Dev server: `cd react/admin && npm run start` (Vite, port 3000)
- Build: `cd react/admin && npm run build` (outputs to `dist/`)
- Tests: `cd react/admin && npm run test` (Vitest + jsdom)
- Single test: `cd react/admin && npm run test -- -t "test name"`
- Watch mode: `cd react/admin && npm run test:watch`

### Lambda Functions (`lambda/api`)
- Lint all: `cd lambda/api && pylint --rcfile .pylintrc */function.py`
- Local test: `cd lambda/api/[function_dir] && python -m function`

### Terraform
- Terraform is applied via CI/CD only (`.github/workflows/terraform.yml`)
- Two stacks: `terraform/dns` (bootstrap) and `terraform/infra` (main)
- Backend: S3 (`cabal-tf-backend` bucket), key pattern `{environment}-{module}`
- Environment determined by branch: `main`=prod, `stage`=stage, other=development
- Backend config is generated at CI time by `.github/scripts/make-terraform.sh`
- Security scanning: Checkov, tflint, tfsec all run in the terraform workflow

### Docker Images
- Built and pushed via `.github/workflows/docker.yml`
- Three tiers built in matrix: `imap`, `smtp-in`, `smtp-out`
- Images tagged `sha-{first8}` and pushed to ECR (`cabal-{tier}`)
- A certbot-renewal image is also built (arm64, for Lambda container)
- After build, the workflow triggers `terraform.yml` to deploy

## CI/CD Workflows (`.github/workflows/`)

| Workflow | Trigger (path) | What it does |
|---|---|---|
| `react.yml` | `react/admin/**` | Build Vite app, sync to S3, invalidate CloudFront |
| `lambda_api_python.yml` | `lambda/api/**` | Pylint, build zips, upload to S3, trigger terraform |
| `lambda_counter.yml` | `lambda/counter/**` | Pylint, build zip, upload to S3, trigger terraform |
| `docker.yml` | `docker/**` | Build 3 mail tier images + certbot, push to ECR, trigger terraform |
| `terraform.yml` | `terraform/infra/**` | Checkov/tflint/tfsec, plan, apply. Also runs weekly (Wednesday) |
| `bootstrap.yml` | Manual/workflow_call | Applies `terraform/dns` stack (Route 53 zone) |
All workflows select environment based on branch: `main`=prod, `stage`=stage, other=development.

## Architecture Details

### Terraform Modules (`terraform/infra/modules/`)

| Module | Purpose |
|---|---|
| `vpc` | VPC, subnets (public/private), NAT instance, Route 53 private zone |
| `ecs` | ECS cluster, task definitions, services, target groups, SNS/SQS for reconfiguration |
| `elb` | Network Load Balancer: IMAP (993), SMTP relay (25), submission (587/465) |
| `app` | CloudFront distribution, API Gateway, Lambda functions, SSM parameters |
| `s3` | S3 bucket for React app + Lambda artifacts |
| `ecr` | ECR repositories for container images |
| `efs` | EFS filesystem for mailstore |
| `user_pool` | Cognito User Pool + post-confirmation trigger |
| `table` | DynamoDB `cabal-addresses` table |
| `cert` | ACM certificate for control domain |
| `domains` | Route 53 hosted zones for mail domains |
| `lambda_layers` | Python Lambda layer (shared deps like `imapclient`) |
| `certbot_renewal` | Scheduled Lambda for Let's Encrypt cert renewal |
| `backup` | AWS Backup for DynamoDB + EFS (conditional) |

Image tags are stored in SSM Parameter Store (`/cabal/deployed_image_tag`) and read by Terraform at plan time.

### Lambda Functions (`lambda/api/`)

All Lambda functions are Python, fronted by API Gateway with Cognito authorizer. They share a common helper layer (`lambda/api/python/python/helper.py`) providing:
- IMAP client management (master-user login via SSM-stored password, username format `{user}*admin`)
- DynamoDB address lookups (`cabal-addresses` table)
- S3 message caching (raw email bodies cached at `{user}/{folder}/{id}/raw`)
- Presigned URL generation for attachments (24hr expiry)

Key dependencies: `imapclient==2.3.1`, `dnspython==2.3.0` (installed as Lambda layer). IMAP folder paths use `.` internally but `/` in API requests — all functions normalize with `.replace("/", ".")`.

Response format: `{"statusCode": N, "body": json.dumps({...})}`. User extracted from `event['requestContext']['authorizer']['claims']['cognito:username']`.

| Function | Purpose |
|---|---|
| `list` | List user's email addresses |
| `new` | Create a new email address |
| `revoke` | Delete an email address |
| `list_folders` | List IMAP folders |
| `new_folder` / `delete_folder` | Create/delete IMAP folders |
| `subscribe_folder` / `unsubscribe_folder` | Manage folder subscriptions |
| `list_messages` / `list_envelopes` | List messages / fetch envelope data |
| `fetch_message` | Fetch full email body (with S3 cache) |
| `fetch_attachment` / `list_attachments` / `fetch_inline_image` | Attachment handling |
| `fetch_bimi` | BIMI logo lookup for sender domains |
| `send` | Send email via SMTP |
| `move_messages` / `set_flag` | IMAP message operations |

### React App (`react/admin/`)

- **React 17** with class-based components, Vite build tooling, Vitest for tests
- **Auth**: Amazon Cognito (`amazon-cognito-identity-js`) — signup, login, JWT token management
- **API**: Axios-based `ApiClient` class, all calls include Cognito JWT in Authorization header
- **State**: Component-level state with `localStorage` persistence (no Redux/Context for app state)
- **Contexts**: `AuthContext` (token/api_url/host/domains), `AppMessageContext` (toast notifications)
- **Email**: Rich text compose with Draft.js/react-draft-wysiwyg, DOMPurify for HTML sanitization
- **Key views**: Email (inbox/folders/compose), Addresses (list/request/revoke), Folders (manage), Login/SignUp
- **Config**: Fetched at runtime from `/config.js` (served by CloudFront, generated by Terraform)

### Docker Services (`docker/`)

Three container images based on `amazonlinux:2023`, managed by supervisord:
- **`imap`**: Dovecot (IMAP) + Sendmail (local delivery) + Procmail + fail2ban
- **`smtp-in`**: Sendmail (inbound relay) + fail2ban
- **`smtp-out`**: Sendmail (outbound) + Dovecot (submission auth) + OpenDKIM + fail2ban

Shared infrastructure:
- `docker/shared/entrypoint.sh` — writes TLS certs, renders sendmail.mc, generates Cognito auth script, syncs OS users, generates sendmail maps from DynamoDB
- `docker/shared/generate-config.sh` — scans DynamoDB, generates virtusertable, access maps, relay-domains, DKIM tables
- `docker/shared/reconfigure.sh` — live reconfiguration triggered by SNS/SQS when addresses change
- `docker/shared/sync-users.sh` — creates OS users from Cognito user pool
- `docker/templates/` — sendmail `.mc` templates with `__CERT_DOMAIN__` placeholders

## Code Style Guidelines

- **JavaScript/React**:
  - Class-based React components with explicit state management (soon to migrate to function-based components)
  - Import order: third-party libs, main components, utilities, styles
  - Error handling with try/catch blocks and explicit error messaging
  - Use camelCase for variables/functions, PascalCase for components
  - JSDoc comments for function documentation

- **Python**:
  - Function docstrings using triple quotes
  - Snake_case for variables and functions
  - Disable specific pylint warnings with inline comments when necessary
  - Import standard libs first, then custom modules

- **Terraform**:
  - Follow HashiCorp style conventions
  - Document modules and variables thoroughly
  - Group related resources in modules
  - Use locals for repeated values or complex expressions

- **Docker/Shell**:
  - `set -euo pipefail` in all scripts
  - Structured logging with `[component]` prefixes
  - Environment variable validation at script entry
  - Comments explaining non-obvious configuration choices
