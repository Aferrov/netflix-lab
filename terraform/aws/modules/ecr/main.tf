variable "name" { type = string }

resource "aws_ecr_repository" "this" {
  for_each             = toset(["backend", "frontend"])
  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({ rules = [{
    rulePriority = 1
    description  = "Conservar las 10 imágenes recientes"
    selection = {
      tagStatus   = "any"
      countType   = "imageCountMoreThan"
      countNumber = 10
    }
    action = { type = "expire" }
  }] })
}

output "repository_urls" { value = { for name, repo in aws_ecr_repository.this : name => repo.repository_url } }
