# SNS
## SNS RESOURCES FOR CONFIG
### CONFIG DOES NOT HAVE AN SNS SUBSCRIPTION (YET)
### CONFIG SNS TOPIC
resource "aws_sns_topic" "compliance" {
  name              = "compliance-notifications"
  kms_master_key_id = var.logs_kms_key_arn

  tags = {
    Name      = "ConfigNotifications"
    Terraform = "true"
  }
}

### CONFIG SNS TOPIC POLICY
resource "aws_sns_topic_policy" "compliance" {
  arn = aws_sns_topic.compliance.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "config.amazonaws.com"
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.compliance.arn
    }]
  })
}

## SNS RESOURCES FOR SECURITY
### SECURITY SNS TOPIC
resource "aws_sns_topic" "secops" {
  name              = "security-notifications"
  kms_master_key_id = var.logs_kms_key_arn

  tags = {
    Name      = "CloudtrailNotifications"
    Terraform = "true"
  }
}

### SECOPS SNS TOPIC POLICY
resource "aws_sns_topic_policy" "secops" {
  arn = aws_sns_topic.secops.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudTrailPublish"
        Effect = "Allow"
        Principal = {
          "Service" = "cloudtrail.amazonaws.com"
        }
        Action   = "sns:Publish"
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
  alarm_name          = "Root-User-Activity"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RootActivityCount"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect Root-level activity"
  alarm_actions       = [aws_sns_topic.secops.arn]
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
  alarm_name          = "Unauthorized_API_Calls"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnauthorizedAPICallCount"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect unauthorized API activity"
  alarm_actions       = [aws_sns_topic.secops.arn]
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
  alarm_name          = "CloudTrailDisabled"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CloudTrailDisabled"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect if CloudTrail is disabled"
  alarm_actions       = [aws_sns_topic.secops.arn]
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
  alarm_name          = "IamPolicyChanges"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IamPolicyChanges"
  namespace           = "SecurityBaseline"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Detect any changes made to IAM"
  alarm_actions       = [aws_sns_topic.secops.arn]
}