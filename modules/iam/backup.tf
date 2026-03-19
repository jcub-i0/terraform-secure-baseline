# BACKUP-RELATED IAM RESOURCES

# BACKUP SERVICE-LINKED ROLE
resource "aws_iam_role" "backup" {
  name = "backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "backup.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}