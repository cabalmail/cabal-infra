# CLAUDE.md

## Project Overview

Cabalmail is a personal email hosting infrastructure on AWS. Users get unique email addresses as subdomains (e.g., `foo@bar.example.com`), with spam control via DNS revocation instead of computational filtering.

## Repository Structure

```
terraform/   - AWS infrastructure (IaC)
chef/        - Server configuration management (cookbook: cabal v1.0.0)
react/admin/ - Admin web UI (React 17)
lambda/      - AWS Lambda functions (Node.js + Python)
docker/      - Planned containerization (not yet implemented)
docs/        - Project documentation (Jekyll site for GitHub Pages)
.github/     - CI/CD workflows and build scripts
```

## Build & Test Commands

### React Admin UI (`react/admin/`)

```bash
cd react/admin
yarn install
yarn test        # Jest + React Testing Library
yarn build       # Production build
yarn start       # Dev server
```

### Python Lambdas (`lambda/api/python/`)

```bash
# Lint (must pass in CI)
cd lambda/api/python
pylint --rcfile .pylintrc */function.py
```

Each function has its own `requirements.txt`. Dependencies are installed into a `./python` subdirectory for Lambda layer packaging.

### Node.js Lambdas (`lambda/api/node/`)

Each function has a `requirements.txt` listing npm packages (not a `package.json`). The build script runs `npm init --yes && cat requirements.txt | xargs npm install --save` inside each function directory.

### Terraform (`terraform/infra/`)

```bash
cd terraform/infra
terraform init
terraform plan -var-file="terraform.tfvars"
```

Requires a generated `backend.tf` (created by `.github/scripts/make-terraform.sh`). State is stored in Terraform Cloud.

## CI/CD (GitHub Actions)

All workflows are in `.github/workflows/`. Deployments are environment-aware: `main` → prod, `stage` → stage, anything else → development.

| Workflow | Trigger (path) | Key Steps |
|---|---|---|
| `terraform.yml` | `terraform/infra/**` | tflint, tfsec, checkov, plan, apply |
| `react.yml` | `react/admin/src/**`, `react/admin/public/**` | yarn build → S3 + CloudFront |
| `lambda_api_python.yml` | `lambda/api/python/**` | pylint → zip → S3 → terraform apply |
| `lambda_api_node.yml` | `lambda/api/node/**` | npm install → zip → S3 → terraform apply |
| `lambda_counter.yml` | `lambda/counter/**` | Build → S3 → terraform apply |
| `cookbook.yml` | `chef/**` | tar.gz → S3 |
| `bootstrap.yml` | `terraform/dns/**` | DNS infrastructure setup |

## Linting & Code Quality

- **Terraform**: tflint (AWS ruleset v0.20.0, config in `terraform/.tflint.hcl`), tfsec, checkov
- **Python**: pylint (config in `lambda/api/python/.pylintrc`, fail-under=10)
- **React**: eslint via `react-app` preset (configured in `package.json`)

## Key Conventions

- Terraform modules live under `terraform/infra/modules/`; some modules have nested `modules/` subdirectories
- Lambda functions are individually zipped with SHA256 digests and uploaded to S3
- Chef cookbook is a single `cabal` cookbook at `chef/cabal/`
- AWS provider version: ~5.94.1; Terraform >= 1.1.2
- The React app authenticates via AWS Cognito (`amazon-cognito-identity-js`)

## Files Not to Commit

See `.gitignore` — notably: `terraform.tfvars`, `.terraform/`, `backend.tf`, `backend.hcl`, `react/admin/public/config.js`
