############################################
# TAMPER DETECTION — EVENTBRIDGE → SNS
############################################

locals {
  tamper_actions = [
    # CLOUDTRAIL TAMPERING
    "cloudtrail:StopLogging",
    "cloudtrail:DeleteTrail",
    "cloudtrail:UpdateTrail",
    "cloudtrail:PutEventSelectors",
    "cloudtrail:PutInsightSelectors",

    # GUARDDUTY TAMPERING
    "guardduty:DeleteDetector",
    "guardduty:UpdateDetector",
    "guardduty:DisassociateFromMasterAccount",
    "guardduty:DisassociateMembers",

    # SECURITY HUB TAMPERING
    "securityhub:DisableSecurityHub",
    "securityhub:DeleteMembers",
    "securityhub:DisassociateFromMasterAccount",

    # KMS TAMPERING
    "kms:ScheduleKeyDeletion",
    "kms:DisableKey",
    "kms:PutKeyPolicy",
    "kms:UpdateKeyDescription"
  ]
}

# ALLOW EVENTBRIDGE TO PUBLISH TO THE SNS TOPIC


# TAMPER DETECTION EVENTBRIDGE RULE
resource "aws_cloudwatch_event_rule" "tamper_detection" {
  name = "${var.name_prefix}-tamper-detection"
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
}

# SEND TO SNS TOPIC FOR NOTIFICATION
resource "aws_cloudwatch_event_target" "tamper_to_sns" {
  rule = aws_cloudwatch_event_rule.tamper_detection.name
  target_id = "TamperAlertsToSNS"
  arn = var.alert_topic_arn
}