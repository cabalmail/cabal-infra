resource "aws_ecr_repository" "certbot" {
  name = "cabal/certbot-renewal"
  # IMMUTABLE to match every other cabal ECR repo (the ecr module). Deploys
  # push unique sha-<8> tags (app.yml), so immutability never blocks a push.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Phase 5 ("ECR posture") of docs/0.10.x/identity-iam-hardening-plan.md
# deliberately does NOT put a Terraform-managed aws_ecr_repository_policy
# on this repo, unlike the ECS tier repos (modules/ecr). The certbot
# image is a Lambda container image, and the Lambda service writes its
# own repository policy here on every create / update-function-code (the
# LambdaECRImageRetrievalPolicy statement granting lambda.amazonaws.com
# pull plus ecr:SetRepositoryPolicy/DeleteRepositoryPolicy, scoped to
# function:* in this account). An ECR repo has a single policy document,
# so a Terraform-managed policy would overwrite that statement; Lambda
# re-injects it on the next deploy, and the two then fight on every plan.
# Worse, removing Lambda's SetRepositoryPolicy self-grant can break the
# image-update path. The Lambda-managed policy is the right owner here;
# we leave it alone. The deploy role pushes via its own identity policy
# and does not need a grant here.

resource "aws_ecr_lifecycle_policy" "certbot" {
  repository = aws_ecr_repository.certbot.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 3 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 3
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
