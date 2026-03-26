# SECOPS IAM RESOURCES

## SECOPS-ENGINEER ROLE
resource "aws_iam_role" "secops_engineer" {
  name = "SecOps-Engineer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${var.account_id}:root"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### ATTACH CENTRALIZED LOGS READ ONLY POLICY TO SECOPS-ENGINEER ROLE
resource "aws_iam_role_policy_attachment" "logs_s3_readonly_secops_engineer" {
  role       = aws_iam_role.secops_engineer.name
  policy_arn = aws_iam_policy.logs_s3_readonly.arn
}

### ATTACH LogsKmsReadOnly POLICY TO SECOPS-ENGINEER ROLE
resource "aws_iam_role_policy_attachment" "logs_cmk_decrypt_secops_engineer" {
  role       = aws_iam_role.secops_engineer.name
  policy_arn = aws_iam_policy.logs_cmk_decrypt.arn
}

### ATTACH EC2 ROLLBACK POLICY TO SECOPS-ENGINEER ROLE
resource "aws_iam_role_policy_attachment" "ec2_rollback_secops_engineer" {
  role       = aws_iam_role.secops_engineer.name
  policy_arn = aws_iam_policy.secops_rollback_trigger.arn
}

### READ ACCESS FOR SECOPS-ENGINEER ROLE
resource "aws_iam_role_policy_attachment" "securityhub_readonly_secops_engineer" {
  role       = aws_iam_role.secops_engineer.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSecurityHubReadOnlyAccess"
}

## SECOPS-ANALYST ROLE
resource "aws_iam_role" "secops_analyst" {
  name = "SecOps-Analyst"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${var.account_id}:root"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### ALLOW SECOPS-ANALYST SECURITY HUB READONLY ACCESS
resource "aws_iam_role_policy_attachment" "secops_analyst_securityhub_read" {
  role       = aws_iam_role.secops_analyst.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSecurityHubReadOnlyAccess"
}

### ALLOW SECOPS-ANALYST GUARDDUTY READONLY ACCESS
resource "aws_iam_role_policy_attachment" "secops_analyst_guardduty_read" {
  role       = aws_iam_role.secops_analyst.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonGuardDutyReadOnlyAccess"
}

### ALLOW SECOPS-ANALYST CONFIG READONLY ACCESS
resource "aws_iam_role_policy_attachment" "secops_analyst_config_read" {
  role       = aws_iam_role.secops_analyst.name
  policy_arn = "arn:aws:iam::aws:policy/AWSConfigUserAccess"
}

### ALLOW SECOPS-ANALYST CLOUDWATCH READONLY ACCESS
resource "aws_iam_role_policy_attachment" "secops_analyst_cloudwatch_read" {
  role       = aws_iam_role.secops_analyst.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

### ALLOW SECOPS-ANALYST CLOUDTRAIL READONLY ACCESS
resource "aws_iam_role_policy_attachment" "secops_analyst_cloudtrail_read" {
  role       = aws_iam_role.secops_analyst.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess"
}

### ALLOW SECOPS-ANALYST READONLY ACCESS TO THE CENTRALIZED LOGS BUCKET
resource "aws_iam_role_policy_attachment" "secops_analyst_logs_s3_readonly" {
  role       = aws_iam_role.secops_analyst.name
  policy_arn = aws_iam_policy.logs_s3_readonly.arn
}