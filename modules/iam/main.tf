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