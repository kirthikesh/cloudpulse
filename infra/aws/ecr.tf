# Two ECR repositories: one for the container image, one for the Helm chart (OCI artifact).

locals {
  ecr_repos = {
    app   = var.project
    chart = "charts/${var.project}"
  }
}

resource "aws_ecr_repository" "this" {
  for_each             = local.ecr_repos
  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # a tag always points at the same build
  force_delete         = true        # lets `terraform destroy` clean up after demos

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 artifacts"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}
