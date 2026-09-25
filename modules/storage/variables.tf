variable "cloud_name" {
  description = "Cloud/platform name used in shared resource prefixes."
  type        = string
}

variable "primary_region" {
  description = "Primary AWS region for the workload."
  type        = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "db_port" {
  type = string
}

variable "compute_sg_id" {
  type = string
}

variable "data_private_subnet_ids_list" {
  description = "list(string) of Data Private Subnet IDs"
  type        = list(string)
}

variable "rds_multi_az" {
  description = "Whether the RDS DB instance uses a Multi-AZ deployment."
  type        = bool
}

variable "db_username" {
  type = string
}

variable "logs_cmk_arn" {
  type = string
}

variable "cloudwatch_retention_days" {
  type = string
}

variable "account_id" {
  description = "The ID of the AWS account Terraform is using"
  type        = string
}

variable "random_id" {
  description = "Random string of characters"
  type        = string
}

variable "cloudtrail_arn" {
  type = string
}

variable "bucket_admin_principals" {
  type = list(string)
}

variable "secrets_manager_cmk_arn" {
  type = string
}

variable "backup_enabled" {
  description = "Whether to enable AWS Backup. Set to null to use the deployment_profile default."
  type        = bool
}

variable "rds_deletion_protection" {
  description = "Whether deletion protection is enabled on the RDS DB instance."
  type        = bool
}

variable "rds_skip_final_snapshot" {
  description = "Whether to skip creation of a final RDS snapshot when the DB instance is deleted."
  type        = bool
}

variable "rds_delete_automated_backups" {
  description = "Whether RDS automated backups are deleted immediately when the DB instance is deleted."
  type        = bool
}

variable "rds_final_snapshot_identifier" {
  description = "Identifier used for the final RDS snapshot when final snapshots are enabled."
  type        = string
  default     = null
}