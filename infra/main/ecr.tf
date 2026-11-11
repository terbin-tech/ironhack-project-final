resource "aws_ecr_repository" "this" {
  for_each = toset(["frontend", "backend"])

  name                 = "martin-expensy-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
