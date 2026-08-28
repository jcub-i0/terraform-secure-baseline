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
  # Network Firewall domain allowlist
  #
  # Platform-required domains remain baseline-owned. Application domains are
  # included only when Network Firewall is the effective egress mode.
  # ---------------------------------------------------------------------------
  platform_required_egress_domains = toset([
    ".ubuntu.com",
    ".security.ubuntu.com",
    ".archive.ubuntu.com",
    ".ntp.ubuntu.com",
    ".ec2.archive.ubuntu.com",
  ])

  effective_allowed_egress_domains = (
    local.effective_egress_mode == "network_firewall"
    ? setunion(
      local.platform_required_egress_domains,
      var.allowed_egress_domains,
    )
    : toset([])
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
  # ECS
  # ---------------------------------------------------------------------------

  ecs_required_repositories = {
    for repository_name in toset([
      for service in values(var.ecs_services) :
      service.repository_name
    ]) :
    repository_name => {}
  }

  effective_repositories = merge(
    var.repositories,
    local.ecs_required_repositories,
  )

  ecs_alb_services = {
    for service_name, service in var.ecs_services :
    service_name => {
      container_port    = service.container_port
      priority          = service.ingress.priority
      host_headers      = service.ingress.host_headers
      path_patterns     = service.ingress.path_patterns
      health_check_path = service.ingress.health_check_path
    }
    if service.ingress != null
  }

  ecs_log_group_arns = {
    for service_name in keys(var.ecs_services) :
    service_name => "arn:${data.aws_partition.current.partition}:logs:${var.primary_region}:${var.account_id}:log-group:/ecs/${local.name_prefix}/${service_name}"
  }

  ecs_iam_services = {
    for service_name, service in var.ecs_services :
    service_name => {
      ecr_repository_arns = toset([
        module.ecr.repositories[service.repository_name].arn
      ])

      log_group_arns = toset([
        local.ecs_log_group_arns[service_name]
      ])

      execution_secret_arns = toset(
        values(service.secrets_manager_secrets)
      )

      execution_ssm_parameter_arns = toset(
        values(service.ssm_parameters)
      )

      execution_kms_key_arns = service.execution_kms_key_arns
    }
  }

  ecs_runtime_services = {
    for service_name, service in var.ecs_services :
    service_name => {
      image = "${module.ecr.repositories[service.repository_name].repository_url}@${service.image_digest}"

      container_port = service.container_port
      cpu            = service.cpu
      memory         = service.memory
      desired_count  = service.desired_count

      execution_role_arn = module.iam.ecs_task_execution_roles[service_name].arn
      task_role_arn      = module.iam.ecs_task_roles[service_name].arn

      target_group_arn = (
        service.ingress != null
        ? module.module.application_load_balancer[0].target_groups[service_name].arn
        : null
      )

      cpu_architecture = service.cpu_architecture

      environment_variables = service.environment_variables

      secrets = merge(
        service.secrets_manager_secrets,
        service.ssm_parameters,
      )
    }
  }

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

  effective_inspector_resource_types = distinct(concat(
    var.inspector_resource_types,
    length(local.effective_repositories) > 0 ? ["ECR"] : [],
  ))
}