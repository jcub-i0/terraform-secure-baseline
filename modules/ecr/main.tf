resource "aws_ecr_repository" "repositories" {
  for_each = var.repositories

  name                 = "${var.name_prefix}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # CHANGE THIS IN PROD

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = {
    Name        = each.value
    Environment = var.environment
    Terraform   = "true"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 256
      error_message = "The complete ECR repository name must not exceed 256 characters."
    }
  }
}

resource "aws_ecr_lifecycle_policy" "untagged_cleanup" {
  for_each = aws_ecr_repository.repositories

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 30 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
