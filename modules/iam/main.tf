# IAM ACCESS ANALYZER
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "account-access-analyzer"
  type          = "ACCOUNT"

  tags = {
    Terraform = "true"
  }
}

# CONFIG SERVICE-LINKED ROLE
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

# CONFIG REMEDIATION ROLE
resource "aws_iam_role" "config_remediation" {
  name = "ConfigRemediationRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })
}

data "aws_iam_policy" "ssm_automation" {
  name = "AmazonSSMAutomationRole"
}

resource "aws_iam_role_policy_attachment" "config_ssm_automation" {
  role       = aws_iam_role.config_remediation.name
  policy_arn = data.aws_iam_policy.ssm_automation.arn
}

## CONFIG REMEDIATION S3 PUBLIC ACCESS BLOCK POLICY
resource "aws_iam_role_policy" "s3_public_remediation" {
  name = "S3PublicAccessBlockRemediation"
  role = aws_iam_role.config_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ]
        Resource = "*"
      }
    ]
  })
}

# SECOPS IAM RESOURCES
## SECOPS-OPERATOR IAM ROLE TRUST POLICY
resource "aws_iam_role" "secops_operator" {
  name        = "SecOps-Operator"
  description = "Role exclusively assumed to trigger the EC2 Rollback Lambda function"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = concat(
            [
              "arn:aws:iam::${var.account_id}:user/baseline-admin",
              aws_iam_role.secops_engineer.arn,
            ],
            var.secops_operator_trusted_principal_arns
          )
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

### ATTACH SECURITY OPERATIONS POLICY TO SECOPS-OPERATOR ROLE
resource "aws_iam_role_policy_attachment" "ec2_rollback_secops" {
  role       = aws_iam_role.secops_operator.name
  policy_arn = aws_iam_policy.secops_rollback_trigger.arn
}

### ATTACH LogsKmsReadOnly POLICY TO SECOPS-OPERATOR ROLE
resource "aws_iam_role_policy_attachment" "logs_kms_decrypt_secops" {
  policy_arn = aws_iam_policy.logs_kms_decrypt.arn
  role       = aws_iam_role.secops_operator.name
}

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
resource "aws_iam_role_policy_attachment" "logs_kms_decrypt_secops_engineer" {
  role       = aws_iam_role.secops_engineer.name
  policy_arn = aws_iam_policy.logs_kms_decrypt.arn
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

## SECOPS-ANALSYT ROLE
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

## GENERIC POLICY TO ALLOW READ ACCESS TO CENTRALIZED LOGS S3 BUCKET
resource "aws_iam_policy" "logs_s3_readonly" {
  name        = "CentralizedLogsS3ReadOnly"
  description = "Read-only access to Centralized Logs S3 bucket (no delete, no write)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # LIST BUCKET + READ BUCKET METADATA
      {
        Sid    = "ListCentralizedLogsBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = var.centralized_logs_bucket_arn
      },
      # READ OBJECTS + VERSIONS
      {
        Sid    = "ReadCentralizedLogsObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${var.centralized_logs_bucket_arn}/*"
      }
    ]
  })
}

## GENERIC POLICY TO ALLOW DECRYPTION OF OBJECTS ENCRYPTED WITH THE LOGS CMK
resource "aws_iam_policy" "logs_kms_decrypt" {
  name        = "LogsKmsDecrypt"
  description = "Allow decryption of objects encrypted with the Logs CMK"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowDecryptLogsKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.logs_cmk_arn
      }
    ]
  })
}

### EC2 ROLLBACK TRIGGER POLICY
resource "aws_iam_policy" "secops_rollback_trigger" {
  name = "SecOpsRollbackTriggerPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEc2RollbackEventOnly"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = "arn:aws:events:${var.primary_region}:${var.account_id}:event-bus/security-operations-bus"
      }
    ]
  })
}

# EVENTBRIDGE ROLE
resource "aws_iam_role" "eventbridge_putevents_to_secops" {
  name = "EventBridgePutEventsToSecopsBus"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ALLOW EVENTBRIDGE TO PUT EVENTS TO SECOPS BUS
resource "aws_iam_role_policy" "eventbridge_putevents_to_secops" {
  role = aws_iam_role.eventbridge_putevents_to_secops.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = var.secops_event_bus_arn
    }]

  })
}