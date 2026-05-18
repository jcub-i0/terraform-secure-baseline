# BACKUP-RELATED IAM RESOURCES

# PULL THE AWS-MANAGED BACKUP ROLE POLICY FOR BACKUP CREATION
data "aws_iam_policy" "backup" {
  name = "AWSBackupServiceRolePolicyForBackup"
}

# PULL THE AWS-MANAGED BACKUP ROLE POLICY FOR BACKUP RESTORATION
data "aws_iam_policy" "backup_restore" {
  name = "AWSBackupServiceRolePolicyForRestores"
}

# AWS BACKUP SERVICE TRUST POLICY
data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    sid = "AllowAWSBackupServiceAssumeRole"
    effect = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

# AWS BACKUP SERVICE ROLE
resource "aws_iam_role" "backup" {
  name = "${var.name_prefix}-backup-role"

  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json
}

# ATTACH AWS-MANAGED BACKUP POLICIES
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}