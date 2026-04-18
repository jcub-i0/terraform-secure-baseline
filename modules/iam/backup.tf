# BACKUP-RELATED IAM RESOURCES

# PULL THE AWS-MANAGED BACKUP ROLE POLICY FOR BACKUP CREATION
data "aws_iam_policy" "backup" {
  name = "AWSBackupServiceRolePolicyForBackup"
}

# PULL THE AWS-MANAGED BACKUP ROLE POLICY FOR BACKUP RESTORATION
data "aws_iam_policy" "backup_restore" {
  name = "AWSBackupServiceRolePolicyForRestores"
}

# AWS BACKUP SERVICE ROLE
resource "aws_iam_role" "backup" {
  name = "${var.name_prefix}-backup-role"

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

# ATTACH AWS-MANAGED BACKUP POLICIES
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = data.aws_iam_policy.backup.arn
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = data.aws_iam_policy.backup_restore.arn
}