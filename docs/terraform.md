# Setting Up Terraform

You do not need to install Terraform locally, and you do not need a HashiCorp account. Terraform is planned and applied exclusively by CI/CD: the "Build and Deploy Infrastructure" workflow ([`.github/workflows/infra.yml`](../.github/workflows/infra.yml)) owns both stacks -- `terraform/dns` (the bootstrap stack) and `terraform/infra` (everything else). Earlier versions of this repository drove Terraform through Terraform Cloud workspaces; that integration is gone. No Terraform Cloud workspaces, variables, or API tokens are needed.

The one Terraform-specific resource you must create by hand is the S3 bucket that stores remote state.

## State backend

The backend configuration is not committed. At CI time, [`make-terraform.sh`](../.github/scripts/make-terraform.sh) writes a `backend.tf` into the stack being deployed:

| Setting | Value |
| --- | --- |
| Bucket | `cabal-tf-backend` |
| Key, `terraform/infra` stack | The environment's `TF_VAR_ENVIRONMENT` value, e.g. `production` |
| Key, `terraform/dns` stack | `TF_VAR_ENVIRONMENT` plus `-bootstrap`, e.g. `production-bootstrap` |
| Region | The environment's `TF_VAR_AWS_REGION` value |

One bucket serves every environment; each environment-stack pair gets its own key.

There is no DynamoDB lock table. Concurrent runs are prevented in the workflow instead: a GitHub Actions concurrency group serializes runs per branch and never cancels an in-flight apply.

### Creating the bucket

S3 bucket names are globally unique, so your fork cannot reuse `cabal-tf-backend`. Pick a name of your own and change the `bucket` value in [`make-terraform.sh`](../.github/scripts/make-terraform.sh).

Create the bucket before the first workflow run, in the same region as `TF_VAR_AWS_REGION`:

- Enable bucket versioning. State files are the one thing you will be glad to have old versions of.
- Keep "Block all public access" on and leave Object Ownership at the default "bucket owner enforced".
- Default encryption (SSE-S3) is sufficient.

### Cross-account access

Each environment (prod, stage, development) runs in its own AWS account, but all of their state lives in this one bucket, which exists in exactly one of those accounts (or in a separate account altogether). The `cicd` user in each environment account already has the identity-side S3 permission (see [AWS setup](./aws.md) step 5), but identity-side permission alone does not cross account boundaries: for every environment account other than the one that owns the bucket, the bucket's policy must also grant access. In the bucket-owner account, attach a bucket policy like this, listing each foreign-account `cicd` user:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CrossAccountTerraformState",
            "Effect": "Allow",
            "Principal": {
                "AWS": [
                    "arn:aws:iam::222222222222:user/cicd",
                    "arn:aws:iam::333333333333:user/cicd"
                ]
            },
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::cabal-tf-backend",
                "arn:aws:s3:::cabal-tf-backend/*"
            ]
        }
    ]
}
```

The bucket-owner account's own `cicd` user needs no statement here.

## How the workflow drives plan and apply

The workflow runs on pushes to the three named branches -- `main` (prod), `stage` (stage), and `development` (development) -- that touch `terraform/dns/**`, `terraform/infra/**`, the workflow itself, or its helper scripts. It can also be run manually from the Actions tab (`workflow_dispatch`). Pushes from any other branch never deploy.

The branch selects the GitHub Environment, and the environment supplies everything Terraform needs: AWS credentials come from the repository secrets, and `terraform.tfvars` is assembled at CI time from the environment's `TF_VAR_*` variables. There is no committed tfvars file; [GitHub setup](./github.md) documents every secret and variable. For each stack the sequence is:

1. **Generate the backend.** `make-terraform.sh` writes `backend.tf` as described above.
2. **Scan.** Checkov, tflint, and Trivy scan the stack. A finding that is not in the stack's checked-in baseline/ignore files fails the job and blocks the apply.
3. **Plan.** `terraform plan -detailed-exitcode`. If the plan is empty, the stack's run stops here.
4. **Approve.** When the plan has changes and all scanners passed, an approval job runs against the environment's `gate-*` counterpart (`gate-prod`, `gate-stage`, `gate-development`). If you added required reviewers to the gate environments ([GitHub setup](./github.md)), the run pauses here for a human; otherwise the gate passes on its own.
5. **Apply.** `terraform apply -auto-approve`.
6. **Post-apply.** Any ECS service whose task-definition family advanced during the apply is rolled to the new revision.

The plan and apply jobs also reconcile the deployed Docker image tags and the deployed Lambda code hashes with what is actually running, so a topology-only Terraform change does not roll back an application deploy that happened out of band via the "Build and Deploy Application" workflow. Image tags are tracked per tier: each `cabal-*` ECS service's running tag is copied into the SSM parameter `/cabal/deployed_image_tag/<tier>` before plan, and each task definition reads its own tier's parameter, so tiers that deploy at different times keep their own tags. The legacy global parameter `/cabal/deployed_image_tag` remains as the fallback for any tier whose per-tier key has not been written yet, and as the bootstrap-sentinel carrier for brand-new environments.

## The dns bootstrap stage

`terraform/dns` stands up the Route 53 zone for the control domain. It is a separate stack because its output (the zone's name servers) must be applied to your domain registration before the main stack's certificate validation can succeed; see the provisioning steps in [setup.md](./setup.md).

Within the same workflow, the bootstrap stage is gated: it runs only when a push actually changes `terraform/dns/**`, or when the workflow is dispatched manually with the bootstrap checkbox set. On every other run it is skipped, and the workflow proceeds directly to the main stack. The bootstrap stage has its own scanner jobs and its own approval against the same `gate-*` environment, and like the main stage it applies only when its plan reports changes.
