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