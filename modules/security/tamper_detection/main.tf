############################################
# TAMPER DETECTION — EVENTBRIDGE ➔ SNS
############################################

locals {
  tamper_actions = [
    # CLOUDTRAIL TAMPERING
    "StopLogging",
    "DeleteTrail",
    "UpdateTrail",
    "PutEventSelectors",
    "PutInsightSelectors",

    # GUARDDUTY TAMPERING
    "DeleteDetector",
    "UpdateDetector",
    "DisassociateFromMasterAccount",
    "DisassociateMembers",

    # SECURITY HUB TAMPERING
    "DisableSecurityHub",
    "DeleteMembers",
    "DisassociateFromMasterAccount",

    # KMS TAMPERING
    "ScheduleKeyDeletion",
    "DisableKey",
    "PutKeyPolicy",
    "UpdateKeyDescription"
  ]
}

# TAMPER DETECTION EVENTBRIDGE RULE
resource "aws_cloudwatch_event_rule" "tamper_detection" {
  name        = "${var.name_prefix}-tamper-detection"
  description = "Detect attempts to disable/modify security controls (CloudTrail/GuardDuty/KMS) and alert via SNS"

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"],
    "detail" = {
      "eventSource" = [
        "cloudtrail.amazonaws.com",
        "guardduty.amazonaws.com",
        "securityhub.amazonaws.com",
        "kms.amazonaws.com"
      ],
      "eventName" = local.tamper_actions
    }
  })

  tags = {
    Name        = "${var.name_prefix}-TamperDetectionEventRule"
    Environment = var.environment
    Terraform   = "true"
  }
}

# SEND TO SNS TOPIC FOR NOTIFICATION
resource "aws_cloudwatch_event_target" "tamper_to_sns" {
  rule      = aws_cloudwatch_event_rule.tamper_detection.name
  target_id = "TamperAlertsToSNS"
  arn       = var.alert_topic_arn

  input_transformer {
    input_paths = {
      time        = "$.time"
      account     = "$.account"
      region      = "$.region"
      event_name  = "$.detail.eventName"
      event_src   = "$.detail.eventSource"
      actor       = "$.detail.userIdentity.arn"
      source_ip   = "$.detail.sourceIPAddress"
      mfa         = "$.detail.userIdentity.sessionContext.attributes.mfaAuthenticated"
    }

    input_template = <<EOT
"🚨 SECURITY CONTROL TAMPERING DETECTED 🚨"
"-------------------------------------------------------------------------------------------------"
"Action: <event_name>"
"Service: <event_src>"
"Time: <time>"
"Account: <account>"
"Region: <region>"
""
"Actor: <actor>"
"Source IP: <source_ip>"
"MFA: <mfa>"
"-------------------------------------------------------------------------------------------------"
"This may indicate an attempt to disable or modify security controls."
"Immediately investigate and validate this activity."
EOT
  }

  depends_on = [
    aws_cloudwatch_event_rule.tamper_detection
  ]
}