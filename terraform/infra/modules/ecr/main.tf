/**
* Creates ECR repositories for the containerized mail service tiers.
*/

resource "aws_ecr_repository" "tier" {
  for_each             = toset(concat(var.tiers, var.extra_repositories))
  name                 = "cabal-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Phase 6 of docs/0.9.x/build-deploy-simplification-plan.md: monitoring
# tier ECR repos get prevent_destroy so neither toggling var.monitoring
# off nor trimming the docker matrix in app.yml can destroy historical
# images. The repos themselves are still created unconditionally; only
# the ECS services that consume them are gated by var.monitoring.
resource "aws_ecr_repository" "monitoring" {
  for_each             = toset(var.monitoring_repositories)
  name                 = "cabal-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# SMTP sinkhole test fixture (docs/0.9.x/sinkhole-test-harness-plan.md).
# Same prevent_destroy posture as the monitoring repos: the ECR repo is
# created unconditionally so images can be pre-built and history is
# preserved, while the ECS tier consuming it is gated by var.sinkhole.
# A separate resource (not folded into monitoring_repositories) keeps
# the semantic distinction clear: sinkhole is a test fixture, not a
# monitoring service.
resource "aws_ecr_repository" "sinkhole" {
  name                 = "cabal-sinkhole"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  all_repositories = merge(
    aws_ecr_repository.tier,
    aws_ecr_repository.monitoring,
    { sinkhole = aws_ecr_repository.sinkhole },
  )

  # Repository (resource-level) ECR pull actions. ecr:GetAuthorizationToken
  # is deliberately excluded: it is a registry-level action that cannot be
  # scoped to a single repository, so it lives in identity policies, not
  # here. See var.allowed_pull_principal_arns.
  ecr_pull_actions = [
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchGetImage",
    "ecr:BatchCheckLayerAvailability",
  ]
}

# Phase 5 ("ECR posture") of docs/0.10.x/identity-iam-hardening-plan.md.
# Without a repository policy an ECR repo grants pull to any account
# principal that holds ecr:* through an identity policy. Every repo here
# is consumed only by the ECS agent - the imap/smtp tiers and the
# sinkhole fixture pull under cabal-ecs-execution-role, each monitoring
# tier under its own cabal-<tier>-execution role - and is pushed and
# scanned by the CI deploy role. The caller supplies the exact allow list
# per repo (see var.allowed_pull_principal_arns). The Deny statement is
# what actually restricts pull: it fires for every principal whose ARN is
# not in that repo's allow list. The Allow statement keeps the legitimate
# pullers working (an allow-only policy would be a no-op, since
# same-account access already unions identity and resource grants).
# aws:PrincipalArn resolves to the role ARN for an assumed-role session,
# so matching the role ARNs catches the ECS agent and the OIDC deploy
# role regardless of session name. Repos with no entry in the map (a
# future var.extra_repositories, say) get no policy rather than a
# lockout.
resource "aws_ecr_repository_policy" "pull_restriction" {
  for_each = {
    for key, repo in local.all_repositories : key => repo
    if contains(keys(var.allowed_pull_principal_arns), key)
  }
  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowPullForCabalPrincipals"
        Effect    = "Allow"
        Principal = { AWS = var.allowed_pull_principal_arns[each.key] }
        Action    = local.ecr_pull_actions
      },
      {
        Sid       = "DenyPullForOtherPrincipals"
        Effect    = "Deny"
        Principal = "*"
        Action    = local.ecr_pull_actions
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = var.allowed_pull_principal_arns[each.key]
          }
        }
      },
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "tier" {
  for_each   = local.all_repositories
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
