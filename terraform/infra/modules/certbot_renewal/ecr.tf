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
