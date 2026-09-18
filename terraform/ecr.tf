# Container registry. GitHub Actions builds an image, pushes it here, then tells
# Kubernetes to roll out that exact tag.

resource "aws_ecr_repository" "app" {
  name = "${local.name}-api"

  # IMMUTABLE means a tag can never be repointed at a different image. This is
  # the single most valuable setting here: with mutable tags, "the image running
  # in production" is not a fact you can recover later, because someone can push
  # a new image over the same tag. The CD workflow tags by git SHA, so every
  # deploy is traceable to a commit.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Images are rebuilt from source on every deploy, so losing the repository
  # costs nothing but a rebuild -- let terraform destroy remove it even when
  # images are present.
  force_delete = true

  tags = { Name = "${local.name}-api" }
}

# Without this, every image ever built is stored forever at $0.10/GB-month.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 10 most recent images, expire older ones"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThanOne"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
