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

  deployable_ecs_services = {
    for service_name, service in var.ecs_services :
    service_name => service
    if service.image_digest != null
  }

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
    for service_name, service in local.deployable_ecs_services :
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
    for service_name in keys(local.deployable_ecs_services) :
    service_name => "arn:${data.aws_partition.current.partition}:logs:${var.primary_region}:${var.account_id}:log-group:/aws/ecs/${local.name_prefix}/${service_name}"
  }

  guardduty_fargate_agent_ecr_account_ids = {
    "af-south-1"     = "197869348890"
    "ap-east-1"      = "258348409381"
    "ap-east-2"      = "259886477082"
    "ap-northeast-1" = "533107202818"
    "ap-northeast-2" = "914738172881"
    "ap-northeast-3" = "273192626886"
    "ap-south-1"     = "251508486986"
    "ap-south-2"     = "950823858135"
    "ap-southeast-1" = "174946120834"
    "ap-southeast-2" = "005257825471"
    "ap-southeast-3" = "510637619217"
    "ap-southeast-4" = "251357961535"
    "ap-southeast-5" = "156041399949"
    "ap-southeast-7" = "054037130133"
    "ca-central-1"   = "354763396469"
    "ca-west-1"      = "339712888787"
    "eu-central-1"   = "323658145986"
    "eu-central-2"   = "529164026651"
    "eu-north-1"     = "591436053604"
    "eu-south-1"     = "266869475730"
    "eu-south-2"     = "919611009337"
    "eu-west-1"      = "694911143906"
    "eu-west-2"      = "892757235363"
    "eu-west-3"      = "665651866788"
    "il-central-1"   = "870907303882"
    "me-central-1"   = "000014521398"
    "me-south-1"     = "536382113932"
    "mx-central-1"   = "311141559934"
    "sa-east-1"      = "758426053663"
    "us-east-1"      = "593207742271"
    "us-east-2"      = "307168627858"
    "us-west-1"      = "684579721401"
    "us-west-2"      = "733349766148"
  }

  guardduty_fargate_agent_ecr_account_id = (
    local.effective_guardduty_fargate_runtime_monitoring_enabled
    ? local.guardduty_fargate_agent_ecr_account_ids[var.primary_region]
    : null
  )

  guardduty_fargate_agent_ecr_repository_arn = (
    local.effective_guardduty_fargate_runtime_monitoring_enabled
    ? "arn:${data.aws_partition.current.partition}:ecr:${var.primary_region}:${local.guardduty_fargate_agent_ecr_account_id}:repository/aws-guardduty-agent-fargate"
    : null
  )

  ecs_iam_services = {
    for service_name, service in local.deployable_ecs_services :
    service_name => {
      ecr_repository_arns = toset([
        module.ecr.repositories[service.repository_name].arn
      ])

      guardduty_agent_ecr_repository_arns = (
        local.effective_guardduty_fargate_runtime_monitoring_enabled
        ? toset([
          local.guardduty_fargate_agent_ecr_repository_arn
        ])
        : toset([])
      )

      log_group_arns = toset([
        local.ecs_log_group_arns[service_name]
      ])

      execution_secret_arns = toset(
        values(service.secrets_manager_secrets)
      )

      execution_ssm_parameter_arns = toset(
        values(service.ssm_parameters)
      )

      task_execution_kms_key_arns = service.task_execution_kms_key_arns
    }
  }

  ecs_runtime_services = {
    for service_name, service in local.deployable_ecs_services :
    service_name => {
      image = "${module.ecr.repositories[service.repository_name].repository_url}@${service.image_digest}"

      container_port = service.container_port
      cpu            = service.cpu
      memory         = service.memory
      desired_count  = service.desired_count
      scaling        = service.scaling
      deployment     = service.deployment

      execution_role_arn = module.iam.ecs_task_execution_roles[service_name].arn
      task_role_arn      = module.iam.ecs_task_roles[service_name].arn

      target_group_arn = (
        service.ingress != null
        ? module.application_load_balancer[0].target_groups[service_name].arn
        : null
      )

      alb_request_resource_label = (
        service.ingress != null
        ? "${module.application_load_balancer[0].load_balancer_arn_suffix}/${module.application_load_balancer[0].target_groups[service_name].arn_suffix}"
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

  ecs_security_policy_services = {
    for service_name, service in local.deployable_ecs_services :
    service_name => {
      task_sg_id     = module.ecs_service.task_security_group_ids[service_name]
      container_port = service.container_port

      alb_sg_id = (
        service.ingress != null
        ? module.application_load_balancer[0].security_group_id
        : null
      )

      alb_access      = service.ingress != null
      database_access = service.database_access
    }
  }

  ecs_security_policy_rule_ids = {
    for service_name, rules in module.security_policy.ecs_sg_rule_ids :
    service_name => toset(compact([
      rules.endpoints_ingress,
      rules.endpoints_egress,
      rules.s3_egress,
      rules.internet_https_egress,
      rules.db_egress,
      rules.db_ingress,
      rules.alb_ingress,
      rules.alb_egress,
    ]))
  }

  ecs_task_deficit_monitoring_services = {
    for service_name, service in local.deployable_ecs_services :
    service_name => {
      cluster_name = module.ecs_cluster.cluster_name
      service_name = "${local.name_prefix}-${service_name}"
    }
    if var.container_insights != "disabled"
  }

  ecs_ingress_monitoring_services = {
    for service_name, service in local.deployable_ecs_services :
    service_name => {
      load_balancer_arn_suffix = module.application_load_balancer[0].load_balancer_arn_suffix
      target_group_arn_suffix  = module.application_load_balancer[0].target_groups[service_name].arn_suffix
    }
    if service.ingress != null
  }

  # ---------------------------------------------------------------------------
  # Cost-sensitive service defaults
  # ---------------------------------------------------------------------------

  effective_backup_enabled = (
    var.backup_enabled != null
    ? var.backup_enabled
    : local.is_production_profile
  )

  profile_default_backup_schedule = "cron(0 5 * * ? *)"

  profile_default_delete_backups_after_days = (
    local.is_production_profile ? 30 : 7
  )

  effective_backup_schedule = (
    local.effective_backup_enabled
    ? coalesce(
      var.backup_schedule,
      local.profile_default_backup_schedule,
    )
    : null
  )

  effective_delete_backups_after_days = (
    local.effective_backup_enabled
    ? coalesce(
      var.delete_backups_after_days,
      local.profile_default_delete_backups_after_days,
    )
    : null
  )

  effective_rds_multi_az = (
    var.rds_multi_az != null
    ? var.rds_multi_az
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

  profile_default_guardduty_fargate_runtime_monitoring_enabled = (
    !local.is_minimal_profile
  )

  effective_guardduty_fargate_runtime_monitoring_enabled = (
    local.profile_default_guardduty_fargate_runtime_monitoring_enabled
  )
}