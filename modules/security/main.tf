data "aws_partition" "current" {}

locals {
  # SecurityHub standards for securityhub_standards_subscriptions resource to loop through
  ## Select the SecurityHub standards you want by uncommenting the respective standard(s)
  securityhub_standards = {
    aws_fsbp = "arn:${data.aws_partition.current.partition}:securityhub:${var.primary_region}::standards/aws-foundational-security-best-practices/v/1.0.0",
    cis      = "arn:${data.aws_partition.current.partition}:securityhub:${var.primary_region}::standards/cis-aws-foundations-benchmark/v/5.0.0",
    #aws_tagging = "arn:${data.aws_partition.current.partition}:securityhub:${var.primary_region}::standards/aws-resource-tagging-standard/v/1.0.0",
    #nist_800 = "arn:${data.aws_partition.current.partition}:securityhub:${var.primary_region}::standards/nist-800-53/v/5.0.0",
    #pci_dss = "arn:${data.aws_partition.current.partition}:securityhub:${var.primary_region}::standards/pci-dss/v/4.0.1"
  }
}

# ENABLE 'BLOCK PUBLIC SHARING' ON SSM DOCUMENTS
resource "aws_ssm_service_setting" "block_ssm_doc_public_sharing" {
  setting_id    = "/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}

# GUARDDUTY
resource "aws_guardduty_detector" "main" {
  #checkov:skip=CKV2_AWS_3:GuardDuty organization enrollment is managed by the security-operations stack and verified by validate-security-operations.sh.
  count = var.manage_guardduty_locally ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  region                       = var.primary_region

  tags = {
    Name        = "${var.name_prefix}-Main"
    Environment = var.environment
    Terraform   = "true"
  }
}

## LOOP THROUGH EACH FEATURE LISTED IN 'var.guardduty_features'
resource "aws_guardduty_detector_feature" "main" {
  for_each = var.manage_guardduty_locally ? toset(var.guardduty_features) : toset([])

  detector_id = aws_guardduty_detector.main[0].id
  name        = each.value
  status      = "ENABLED"

  lifecycle {
    ignore_changes = [
      additional_configuration,
      status
    ]
  }
}

# SECURITY HUB
resource "aws_securityhub_account" "main" {
  count = var.manage_securityhub_cspm_locally ? 1 : 0

  enable_default_standards = true
}

resource "aws_securityhub_account_v2" "main" {
  count = var.manage_securityhub_v2_locally ? 1 : 0
}

## SUBSCRIBE TO EACH SECURITY HUB STANDARD LISTED IN 'local.securityhub_standards'
resource "aws_securityhub_standards_subscription" "main" {
  for_each      = var.manage_securityhub_cspm_locally ? local.securityhub_standards : {}
  standards_arn = each.value
  depends_on    = [aws_securityhub_account.main]
}

# INSPECTOR RESOURCES
## ENABLE INSPECTORv2
resource "aws_inspector2_enabler" "main" {
  count = var.inspector_enabled ? 1 : 0

  account_ids    = [var.account_id]
  resource_types = var.inspector_resource_types

  lifecycle {
    precondition {
      condition     = length(var.inspector_resource_types) > 0
      error_message = "inspector_resource_types must contain at least one resource type when Inspector is enabled."
    }
  }
}

## SUBSCRIBE SECURITY HUB TO AMAZON INSPECTOR PRODUCT
resource "aws_securityhub_product_subscription" "inspector" {
  product_arn = "arn:${data.aws_partition.current.partition}:securityhub:${var.primary_region}::product/aws/inspector"
  depends_on  = [aws_securityhub_account.main]
}

# CONFIG BASELINE MODULE
module "config_baseline" {
  source = "./config_baseline"

  account_id = var.account_id

  name_prefix                  = var.name_prefix
  environment                  = var.environment
  enable_config                = var.enable_config
  compliance_topic_arn         = var.compliance_topic_arn
  centralized_logs_bucket_name = var.centralized_logs_bucket_name
  logs_cmk_arn                 = aws_kms_key.logs.arn
  enable_rules                 = var.enable_rules
}

# TAMPER DETECTION MODULE
module "tamper_detection" {
  source = "./tamper_detection"

  name_prefix                    = var.name_prefix
  cloud_name                     = var.cloud_name
  environment                    = var.environment
  secops_topic_arn               = var.secops_topic_arn
  sec_notifs_eventbridge_dlq_arn = var.sec_notifs_eventbridge_dlq_arn
}