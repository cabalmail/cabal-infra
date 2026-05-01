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

# Phase 6 of docs/0.9.0/build-deploy-simplification-plan.md: monitoring
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

# State migration for the 0.9.5 split. Monitoring repos used to live
# under aws_ecr_repository.tier (via extra_repositories); the rename is
# state-only - no resource is destroyed.
moved {
  from = aws_ecr_repository.tier["uptime-kuma"]
  to   = aws_ecr_repository.monitoring["uptime-kuma"]
}
moved {
  from = aws_ecr_repository.tier["ntfy"]
  to   = aws_ecr_repository.monitoring["ntfy"]
}
moved {
  from = aws_ecr_repository.tier["healthchecks"]
  to   = aws_ecr_repository.monitoring["healthchecks"]
}
moved {
  from = aws_ecr_repository.tier["prometheus"]
  to   = aws_ecr_repository.monitoring["prometheus"]
}
moved {
  from = aws_ecr_repository.tier["alertmanager"]
  to   = aws_ecr_repository.monitoring["alertmanager"]
}
moved {
  from = aws_ecr_repository.tier["grafana"]
  to   = aws_ecr_repository.monitoring["grafana"]
}
moved {
  from = aws_ecr_repository.tier["cloudwatch-exporter"]
  to   = aws_ecr_repository.monitoring["cloudwatch-exporter"]
}
moved {
  from = aws_ecr_repository.tier["blackbox-exporter"]
  to   = aws_ecr_repository.monitoring["blackbox-exporter"]
}
moved {
  from = aws_ecr_repository.tier["node-exporter"]
  to   = aws_ecr_repository.monitoring["node-exporter"]
}

locals {
  all_repositories = merge(
    aws_ecr_repository.tier,
    aws_ecr_repository.monitoring,
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
