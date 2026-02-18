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
