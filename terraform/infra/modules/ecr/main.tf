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
