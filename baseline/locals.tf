############################
# BASELINE LOCAL VARIABLES #
############################

locals {
  # ---------------------------------------------------------------------------
  # Naming
  # ---------------------------------------------------------------------------
  name_prefix = "${var.cloud_name}-${var.environment}"

  # ---------------------------------------------------------------------------
  # Deployment profile flags
  # ---------------------------------------------------------------------------
  is_production_profile  = var.deployment_profile == "production"
  is_development_profile = var.deployment_profile == "development"
  is_minimal_profile     = var.deployment_profile == "minimal"

  # ---------------------------------------------------------------------------
  # Egress mode
  #
  # If egress_mode is "auto", the deployment profile selects the default.
  # Explicit egress_mode values override the profile default.
  # ---------------------------------------------------------------------------
  profile_default_egress_mode = (
    local.is_production_profile ? "network_firewall" :
    local.is_development_profile ? "nat_only" :
    "vpc_endpoints_only"
  )

  effective_egress_mode = (
    var.egress_mode == "auto"
    ? local.profile_default_egress_mode
    : var.egress_mode
  )

  # ---------------------------------------------------------------------------
  # CloudWatch Logs retention
  #
  # If cloudwatch_retention_days is null, the deployment profile selects the
  # default retention period. Explicit values override the profile default.
  # ---------------------------------------------------------------------------
  profile_default_cloudwatch_retention_days = (
    local.is_production_profile ? 90 :
    local.is_development_profile ? 30 :
    14
  )

  effective_cloudwatch_retention_days = (
    var.cloudwatch_retention_days != null
    ? var.cloudwatch_retention_days
    : local.profile_default_cloudwatch_retention_days
  )

  # ---------------------------------------------------------------------------
  # AWS Config
  #
  # If enable_config is null, the deployment profile selects the default.
  # If Config is disabled, all Config rule groups are forced off.
  # ---------------------------------------------------------------------------
  profile_default_enable_config = (
    local.is_production_profile ? true :
    local.is_development_profile ? true :
    false
  )

  effective_enable_config = (
    var.enable_config != null
    ? var.enable_config
    : local.profile_default_enable_config
  )

  disabled_enable_rules = {
    s3_baseline         = false
    cloudtrail_baseline = false
    rds_baseline        = false
    ebs_baseline        = false
    sg_baseline         = false
    iam_baseline        = false
    ec2_baseline        = false
    kms_baseline        = false
  }

  effective_enable_rules = (
    local.effective_enable_config
    ? var.enable_rules
    : local.disabled_enable_rules
  )

  # ---------------------------------------------------------------------------
  # Cost-sensitive service defaults
  # ---------------------------------------------------------------------------

  effective_backup_enabled = (
    var.backup_enabled != null
    ? var.backup_enabled
    : local.is_production_profile
  )

  effective_inspector_enabled = (
    var.inspector_enabled != null
    ? var.inspector_enabled
    : !local.is_minimal_profile
  )
}