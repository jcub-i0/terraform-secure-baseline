# SNS and SQS
## SNS RESOURCES FOR CONFIG
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
data "aws_iam_policy_document" "compliance" {
  statement {
    sid    = "EnableRootPermissions"
    effect = "Allow"
    actions = [
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish"
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    resources = [aws_sns_topic.compliance.arn]
  }

  statement {
    sid     = "AllowConfigPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    resources = [aws_sns_topic.compliance.arn]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "compliance" {
  arn    = aws_sns_topic.compliance.arn
  policy = data.aws_iam_policy_document.compliance.json
}

### COMPLIANCE SNS SUBSCRIPTION
resource "aws_sns_topic_subscription" "compliance" {
  topic_arn = aws_sns_topic.compliance.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.compliance.arn
}

## SQS QUEUE FOR COMPLIANCE SNS
resource "aws_sqs_queue" "compliance" {
  name              = "${var.name_prefix}-compliance-queue"
  kms_master_key_id = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-ComplianceQueue"
    Environment = var.environment
    Terraform   = "true"
  }
}

### POLICY DOCUMENT FOR COMPLIANCE SQS QUEUE
data "aws_iam_policy_document" "compliance_queue_policy" {
  statement {
    sid    = "AllowComplianceTopicToSend"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.compliance.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.compliance.arn]
    }
  }
}

### SQS QUEUE POLICY FOR COMPLIANCE SQS QUEUE
resource "aws_sqs_queue_policy" "compliance" {
  queue_url = aws_sqs_queue.compliance.id
  policy    = data.aws_iam_policy_document.compliance_queue_policy.json
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
data "aws_iam_policy_document" "secops" {
  statement {
    sid    = "EnableRootPermissions"
    effect = "Allow"

    actions = [
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish"
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }

    resources = [aws_sns_topic.secops.arn]
  }

  statement {
    sid     = "AllowCloudWatchPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    resources = [aws_sns_topic.secops.arn]
  }

  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid     = "AllowIpEnrichmentLambdaPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "AWS"
      identifiers = [var.lambda_ip_enrichment_role_arn]
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid     = "AllowEc2IsolationLambdaPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "AWS"
      identifiers = [var.lambda_ec2_isolation_role_arn]
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid     = "AllowEc2RollbackLambdaPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "AWS"
      identifiers = [var.lambda_ec2_rollback_role_arn]
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  # ALLOW BREAK-GLASS EVENT RULE
  statement {
    sid     = "AllowEventBridgePublishBreakGlassAlerts"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.break_glass_assumed.arn]
    }
  }

  # ALLOW TAMPER DETECTION EVENT RULE
  statement {
    sid     = "AllowEventBridgeTamperDetectionAlerts"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = "events.amazonaws.com"
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.tamper_detection_rule_arn]
    }
  }

  # ALLOW SECURITY HUB INSCOPE FINDINGS EVENT RULE
  statement {
    sid     = "AllowSecurityHubFindingAlerts"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.secops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.securityhub_high_critical_rule_arn]
    }
  }
}

resource "aws_sns_topic_policy" "secops" {
  arn    = aws_sns_topic.secops.arn
  policy = data.aws_iam_policy_document.secops.json
}

### SECOPS SNS SUBSCRIPTION
resource "aws_sns_topic_subscription" "secops" {
  for_each = toset(var.secops_emails)

  topic_arn = aws_sns_topic.secops.arn
  protocol  = "email"
  endpoint  = each.value
}

### EVENTBRIDGE TARGET FOR SECURITY HUB HIGH + CRITICAL ALERTS (EVENT RULE LOCATED IN 'AUTOMATION' MODULE)
resource "aws_cloudwatch_event_target" "securityhub_high_critical" {
  rule      = var.securityhub_high_critical_rule_name
  target_id = "sec-hub-to-secops-sns"
  arn       = aws_sns_topic.secops.arn

  input_transformer {
    input_paths = {
      time            = "$.time"
      account         = "$.account"
      region          = "$.region"
      finding_id      = "$.detail.findings[0].Id"
      title           = "$.detail.findings[0].Title"
      severity        = "$.detail.findings[0].Severity.Label"
      product_name    = "$.detail.findings[0].ProductName"
      workflow_status = "$.detail.findings[0].Workflow.Status"
      record_state    = "$.detail.findings[0].RecordState"
      resource_type   = "$.detail.findings[0].Resources[0].Type"
      resource_id     = "$.detail.findings[0].Resources[0].Id"
    }

    input_template = <<-EOT
"🚨 NEW HIGH/CRITICAL SECURITY HUB FINDING 🚨"
"----------------------------------------"
"Severity: <severity>"
"Product: <product_name>"
"Title: <title>"
"Time: <time>"
"Account: <account>"
"Region: <region>"
"Finding ID: <finding_id>"
"Workflow Status: <workflow_status>"
"Record State: <record_state>"
"Resource Type: <resource_type>"
"Resource ID: <resource_id>"
"----------------------------------------"
"Review this finding in Security Hub and validate whether immediate action is required."
EOT
  }
}

### CLOUDWATCH EVENT RULES

##########################################
# BREAK-GLASS ROLE ASSUMPTION DETECTION
##########################################

#### EVENTBRIDGE RULE FOR BREAK-GLASS ADMIN ROLE ASSUMED
resource "aws_cloudwatch_event_rule" "break_glass_assumed" {
  name        = "${var.name_prefix}-break-glass-admin-assumed"
  description = "Alert when the BreakGlass-Admin role is assumed"

  event_pattern = jsonencode({
    source      = ["aws.sts"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["sts.amazonaws.com"]
      eventName   = ["AssumeRole"]
      requestParameters = {
        roleArn = [var.break_glass_admin_role_arn]
      }
    }
  })
}

### EVENTBRIDGE TARGET FOR BREAK-GLASS ADMIN ROLE ASSUMED RULE
resource "aws_cloudwatch_event_target" "break_glass_assumed_to_sns" {
  rule      = aws_cloudwatch_event_rule.break_glass_assumed.name
  target_id = "break-glass-to-secops-sns"
  arn       = aws_sns_topic.secops.arn

  input_transformer {
    input_paths = {
      time       = "$.time"
      account    = "$.account"
      region     = "$.region"
      caller_arn = "$.detail.userIdentity.arn"
      role_arn   = "$.detail.requestParameters.roleArn"
      session    = "$.detail.requestParameters.roleSessionName"
      source_ip  = "$.detail.sourceIPAddress"
      user_agent = "$.detail.userAgent"
    }

    input_template = <<-EOT
"🚨 BREAK-GLASS ROLE ASSUMED! 🚨"
"-------------------------------------------------------------------------------------------------"
"Break-Glass Role Usage Detected - Immediate Validation Required"
"-------------------------------------------------------------------------------------------------"
"Severity: CRITICAL"
"Time: <time>"
"Account: <account>"
"Region: <region>"
"Caller: <caller_arn>"
"Role: <role_arn>"
"Session: <session>"
"Source IP: <source_ip>"
"User Agent: <user_agent>"
"-------------------------------------------------------------------------------------------------"
"This role is restricted to approved emergency use only."
"Immediately verify that this activity is expected and authorized."
EOT
  }

  depends_on = [
    aws_cloudwatch_event_rule.break_glass_assumed
  ]
}

###################################################
# GENERAL CLOUDWATCH LOG METRIC FILTERS AND ALARMS
###################################################

#### ROOT ACTIVITY
resource "aws_cloudwatch_log_metric_filter" "root_activity" {
  name           = "RootActivity"
  log_group_name = var.cloudtrail_logs_group_name

  pattern = "{$.userIdentity.type = \"Root\"}"

  metric_transformation {
    name      = "RootActivityCount"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_activity" {
  alarm_name          = "${var.name_prefix}-Root-User-Activity"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RootActivityCount"
  namespace           = var.name_prefix
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
  log_group_name = var.cloudtrail_logs_group_name

  pattern = "{($.errorCode = \"UnauthorizedOperation\") || ($.errorCode = \"AccessDenied\")}"

  metric_transformation {
    name      = "UnauthorizedAPICallCount"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  alarm_name          = "${var.name_prefix}-Unauthorized_API_Calls"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnauthorizedAPICallCount"
  namespace           = var.name_prefix
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
  log_group_name = var.cloudtrail_logs_group_name

  pattern = "{($.eventName = \"StopLogging\") || ($.eventName = \"DeleteTrail\")}"

  metric_transformation {
    name      = "CloudTrailDisabled"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail_disabled" {
  alarm_name          = "${var.name_prefix}-CloudTrailDisabled"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CloudTrailDisabled"
  namespace           = var.name_prefix
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

### IAM POLICY CHANGES
resource "aws_cloudwatch_log_metric_filter" "iam_policy_changes" {
  name           = "IamPolicyChanges"
  log_group_name = var.cloudtrail_logs_group_name

  pattern = join(" ", [
    "{",
    "($.eventSource = \"iam.amazonaws.com\")",
    "&&",
    "(",
    "($.eventName = \"CreatePolicy\")",
    "|| ($.eventName = \"PutRolePolicy\")",
    "|| ($.eventName = \"AttachRolePolicy\")",
    "|| ($.eventName = \"DeletePolicy\")",
    "|| ($.eventName = \"DetachRolePolicy\")",
    "|| ($.eventName = \"UpdateAssumeRolePolicy\")",
    ")",
    "}",
  ])

  metric_transformation {
    name      = "IamPolicyChanges"
    namespace = var.name_prefix
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "iam_changes" {
  alarm_name          = "${var.name_prefix}-IamPolicyChanges"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "IamPolicyChanges"
  namespace           = var.name_prefix
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