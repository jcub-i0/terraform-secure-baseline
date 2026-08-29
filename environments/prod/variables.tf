variable "cloud_name" {
  description = "The name of this cloud environment"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "deployment_profile" {
  description = "Deployment profile controlling cost/security defaults. Valid values: production, development, minimal."
  type        = string
  default     = "production"

  validation {
    condition = contains([
      "production",
      "development",
      "minimal"
    ], var.deployment_profile)

    error_message = "deployment_profile must be one of: production, development, minimal."
  }
}

variable "egress_mode" {
  description = "Private subnet egress mode. Valid values: network_firewall, nat_only, vpc_endpoints_only, or auto."
  type        = string
  default     = "auto"

  validation {
    condition = contains([
      "auto",
      "network_firewall",
      "nat_only",
      "vpc_endpoints_only"
    ], var.egress_mode)

    error_message = "egress_mode must be one of: auto, network_firewall, nat_only, vpc_endpoints_only."
  }
}

variable "allowed_egress_domains" {
  description = "Environment-approved application egress domains added to the platform-required Network Firewall allowlist. Use exact domains or an initial dot for AWS Network Firewall suffix matching."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for domain in var.allowed_egress_domains :
      length(domain) > 0 &&
      domain == trimspace(domain) &&
      length(regexall("\\s", domain)) == 0 &&
      !strcontains(domain, "://") &&
      !strcontains(domain, "/") &&
      !strcontains(domain, "?") &&
      !strcontains(domain, "#") &&
      !strcontains(domain, "@") &&
      !strcontains(domain, ":") &&
      !strcontains(domain, "*") &&
      !strcontains(domain, "..") &&
      trim(domain, ".") != "" &&
      length(regexall("^\\.?[0-9]+(\\.[0-9]+){3}\\.?$", domain)) == 0
    ])

    error_message = "allowed_egress_domains entries must be exact domains or initial-dot suffix domains, not empty values, URLs, paths, wildcard expressions, IP addresses, or CIDRs."
  }
}

variable "primary_region" {
  description = "Primary Region used"
  type        = string
  default     = "us-east-1"
}

variable "bucket_admin_principals" {
  description = "IAM principal ARNs allowed to administer protected S3 bucket settings."
  type        = list(string)

  validation {
    condition     = length(var.bucket_admin_principals) > 0
    error_message = "bucket_admin_principals must contain at least one IAM principal ARN."
  }
}

variable "abuseipdb_api_key" {
  description = "AbuseIPDB API key for IP Enrichment Lamba"
  type        = string
  sensitive   = true
  default     = null
}

variable "enable_config" {
  description = "Whether to enable AWS Config. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "enable_rules" {
  description = "Rules to be enabled in the 'config_baseline' module"
  type = object({
    s3_baseline         = bool
    cloudtrail_baseline = bool
    rds_baseline        = bool
    ebs_baseline        = bool
    sg_baseline         = bool
    iam_baseline        = bool
    ec2_baseline        = bool
    kms_baseline        = bool
  })

  default = {
    s3_baseline         = true
    cloudtrail_baseline = true
    rds_baseline        = true
    ebs_baseline        = true
    sg_baseline         = true
    iam_baseline        = false
    ec2_baseline        = true
    kms_baseline        = true
  }
}

variable "backup_enabled" {
  description = "Whether to enable AWS Backup. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "inspector_enabled" {
  description = "Whether to enable Amazon Inspector. Set to null to use the deployment_profile default."
  type        = bool
  default     = null
}

variable "inspector_resource_types" {
  description = "Amazon Inspector resource types to enable. Lambda scan types are disabled by default because this baseline encrypts Lambda resources with customer-managed KMS keys, which Inspector Lambda scanning does not support."
  type        = list(string)
  default     = ["EC2"]

  validation {
    condition = alltrue([
      for resource_type in var.inspector_resource_types :
      contains(["EC2", "ECR", "LAMBDA", "LAMBDA_CODE", "CODE_REPOSITORY"], resource_type)
    ])
    error_message = "inspector_resource_types must contain only EC2, ECR, LAMBDA, LAMBDA_CODE, or CODE_REPOSITORY."
  }

  validation {
    condition = (
      !contains(var.inspector_resource_types, "LAMBDA_CODE")
      || contains(var.inspector_resource_types, "LAMBDA")
    )
    error_message = "inspector_resource_types cannot include LAMBDA_CODE unless LAMBDA is also included."
  }
}

variable "break_glass_trusted_principal_arns" {
  description = "ARNs allowed to assume the break-glass admin role. Keep this list extremely small."
  type        = list(string)
  default     = []
}

variable "secops_emails" {
  description = "List of emails to send security-related notifications to"
  type        = list(string)
  default     = []

  # VALIDATE EMAIL FORMATS
  validation {
    condition     = alltrue([for e in var.secops_emails : can(regex("^.+@.+\\..+$", e))])
    error_message = "Each entry in secops_emails must be a valid email address."
  }
}

variable "isolation_allowed" {
  description = "Whether EC2 instances may be automatically isolated by the incident-response Lambda"
  type        = bool
  default     = false
}

variable "manage_securityhub_cspm_locally" {
  description = "Whether this workload account manages its own Security Hub CSPM enablement and standards. Set to false when CSPM is centrally managed from the security-operations account."
  type        = bool
  default     = false
}

variable "manage_securityhub_v2_locally" {
  description = "Whether Security Hub V2 is managed locally instead of through centralized organization policy"
  type        = bool
  default     = false
}

variable "manage_guardduty_locally" {
  description = "Whether this workload account manages its own GuardDuty detector and detector features. Set to false when GuardDuty is centrally managed from the security-operations account."
  type        = bool
  default     = false
}

variable "repositories" {
  description = "Private ECR repositories keyed by repository name."
  type        = map(object({}))
  default     = {}

  validation {
    condition = alltrue([
      for repository_name in keys(var.repositories) :
      can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", repository_name))
    ])

    error_message = "Repository names must use lowercase ECR repository-name syntax."
  }
}

variable "container_insights" {
  description = "CloudWatch Container Insights mode for the ECS cluster"
  type        = string
  default     = "enhanced"

  validation {
    condition = contains([
      "enhanced",
      "enabled",
      "disabled",
    ], var.container_insights)

    error_message = "container_insights must be enhanced, enabled, or disabled."
  }
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN used by the shared ECS Application Load Balancer."
  type        = string
  default     = null
}

variable "alb_ingress_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the shared ECS Application Load Balancer over HTTPS."
  type        = set(string)
  default     = []
}

variable "alb_ssl_policy" {
  description = "TLS security policy used by the shared ECS Application Load Balancer HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}

variable "ecs_services" {
  description = "ECS/Fargate workload services keyed by stable service name."

  type = map(object({
    repository_name = string
    image_digest    = string

    container_port = number
    cpu            = number
    memory         = number
    desired_count  = optional(number, 1)

    cpu_architecture = optional(string, "X86_64")

    database_access = optional(bool, false)

    environment_variables = optional(map(string), {})

    secrets_manager_secrets = optional(map(string), {})
    ssm_parameters          = optional(map(string), {})
    execution_kms_key_arns  = optional(set(string), [])

    ingress = optional(object({
      priority          = number
      host_headers      = optional(set(string), [])
      path_patterns     = optional(set(string), [])
      health_check_path = optional(string, "/health")
    }), null)
  }))

  default = {}
}