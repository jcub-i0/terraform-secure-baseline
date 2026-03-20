# SNS and SQS
## SNS RESOURCES FOR CONFIG
### CONFIG DOES NOT HAVE AN SNS SUBSCRIPTION (YET)
### CONFIG SNS TOPIC
resource "aws_sns_topic" "compliance" {
  name              = "${var.name_prefix}-compliance-notifications"
  kms_master_key_id = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-ConfigNotifications"
    Environment = var.environment
    Terraform   = "true"
  }
}

### CONFIG SNS TOPIC POLICY
resource "aws_sns_topic_policy" "compliance" {
  arn = aws_sns_topic.compliance.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW ROOT
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish"
        ]
        Resource = aws_sns_topic.compliance.arn
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.compliance.arn
      }
    ]
  })
}

### SQS QUEUE FOR COMPLIANCE SNS
resource "aws_sqs_queue" "compliance" {
  name = "${var.name_prefix}-compliance-queue"

  tags = {
    Name = "${var.name_prefix}-ComplianceQueue"
    Environment = var.environment
    Terraform = "true"
  }
}

### COMPLIANCE SNS SUBSCRIPTION
resource "aws_sns_topic_subscription" "compliance" {
  for_each = toset(var.compliance_emails)

  topic_arn = aws_sns_topic.compliance.arn
  protocol  = "email"
  endpoint  = each.value
}

## SNS RESOURCES FOR SECURITY
### SECURITY SNS TOPIC
resource "aws_sns_topic" "secops" {
  name              = "${var.name_prefix}-security-notifications"
  kms_master_key_id = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-CloudtrailNotifications"
    Environment = var.environment
    Terraform   = "true"
  }
}

### SECOPS SNS TOPIC POLICY
resource "aws_sns_topic_policy" "secops" {
  arn = aws_sns_topic.secops.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW ROOT
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action = [
          "SNS:GetTopicAttributes",
          "SNS:SetTopicAttributes",
          "SNS:AddPermission",
          "SNS:RemovePermission",
          "SNS:DeleteTopic",
          "SNS:Subscribe",
          "SNS:ListSubscriptionsByTopic",
          "SNS:Publish"
        ]
        Resource = aws_sns_topic.secops.arn
      },
      {
        Sid    = "AllowCloudWatchPublish"
        Effect = "Allow"
        Principal = {
          "Service" = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.secops.arn
      },
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.secops.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      },
      {
        Sid    = "AllowIpEnrichmentLambdaPublish"
        Effect = "Allow"
        Principal = {
          AWS = var.lambda_ip_enrichment_role_arn
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.secops.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      },
      {
        Sid    = "AllowEc2IsolationLambdaPublish"
        Effect = "Allow"
        Principal = {
          AWS = var.lambda_ec2_isolation_role_arn
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.secops.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      },
      {
        Sid    = "AllowEc2RollbackLambdaPublish"
        Effect = "Allow"
        Principal = {
          AWS = var.lambda_ec2_rollback_role_arn
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.secops.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      }
    ]
  })
}

### SECURITY SNS SUBSCRIPTION
resource "aws_sns_topic_subscription" "secops" {
  for_each = toset(var.secops_emails)

  topic_arn = aws_sns_topic.secops.arn
  protocol  = "email"
  endpoint  = each.value
}

### CLOUDTRAIL LOG METRIC FILTERS AND ALARMS
#### ROOT ACTIVITY
resource "aws_cloudwatch_log_metric_filter" "root_activity" {
  name           = "RootActivity"
  log_group_name = var.cloudtrail_log_group_name

  pattern = "{$.userIdentity.type = \"Root\"}"

  metric_transformation {
    name      = "RootActivityCount"
    namespace = "SecurityBaseline"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_activity" {
  alarm_name          = "${var.name_prefix}-Root-User-Activity"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RootActivityCount"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect Root-level activity"
  alarm_actions       = [aws_sns_topic.secops.arn]

  tags = {
    Name        = "${var.name_prefix}-RootActivityAlarm"
    Environment = var.environment
    Terraform   = "true"
  }
}

### UNAUTHORIZED API CALLS
resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls" {
  name           = "Unauthorized-API-Calls"
  log_group_name = var.cloudtrail_log_group_name

  pattern = "{($.errorCode = \"UnauthorizedOperation\") || ($.errorCode = \"AccessDenied\")}"

  metric_transformation {
    name      = "UnauthorizedAPICallCount"
    namespace = "SecurityBaseline"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  alarm_name          = "${var.name_prefix}-Unauthorized_API_Calls"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnauthorizedAPICallCount"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect unauthorized API activity"
  alarm_actions       = [aws_sns_topic.secops.arn]

  tags = {
    Name        = "${var.name_prefix}-UnauthorizedApiCallsAlarm"
    Environment = var.environment
    Terraform   = "true"
  }
}

### CLOUDTRAIL DISABLED
resource "aws_cloudwatch_log_metric_filter" "cloudtrail_disabled" {
  name           = "CloudTrail-Disabled"
  log_group_name = var.cloudtrail_log_group_name

  pattern = "{($.eventName = \"StopLogging\") || ($.eventName = \"DeleteTrail\")}"

  metric_transformation {
    name      = "CloudTrailDisabled"
    namespace = "SecurityBaseline"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail_disabled" {
  alarm_name          = "${var.name_prefix}-CloudTrailDisabled"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CloudTrailDisabled"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect if CloudTrail is disabled"
  alarm_actions       = [aws_sns_topic.secops.arn]

  tags = {
    Name        = "${var.name_prefix}-CloudtrailDisabledAlarm"
    Environment = var.environment
    Terraform   = "true"
  }
}

### IAM POLICY CHANGES (CONSIDER ALSO ADDING 'DeletePolicy', 'DetachRolePolicy', and 'UpdateAssumeRolePolicy')
resource "aws_cloudwatch_log_metric_filter" "iam_policy_changes" {
  name           = "IamPolicyChanges"
  log_group_name = var.cloudtrail_log_group_name

  pattern = "{ ($.eventSource = \"iam.amazonaws.com\") && (($.eventName = \"CreatePolicy\") || ($.eventName = \"PutRolePolicy\") || ($.eventName = \"AttachRolePolicy\"))}"

  metric_transformation {
    name      = "IamPolicyChanges"
    namespace = "SecurityBaseline"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_changes" {
  alarm_name          = "${var.name_prefix}-IamPolicyChanges"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IamPolicyChanges"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect any changes made to IAM"
  alarm_actions       = [aws_sns_topic.secops.arn]

  tags = {
    Name        = "${var.name_prefix}-IamChangesAlarm"
    Environment = var.environment
    Terraform   = "true"
  }
}