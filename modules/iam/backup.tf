# BACKUP-RELATED IAM RESOURCES

# PULL THE AWS-MANAGED BACKUP ROLE POLICY
data "aws_iam_policy" "backup" {
  name = "AWSBackupServiceRolePolicyForBackup"
}

# AWS BACKUP SERVICE ROLE
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

# ATTACH AWS-MANAGED BACKUP POLICY
resource "aws_iam_role_policy_attachment" "backup" {
  role = aws_iam_role.backup.name
  policy_arn = data.aws_iam_policy.backup.arn
}