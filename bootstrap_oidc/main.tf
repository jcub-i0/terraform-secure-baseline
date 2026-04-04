module "github_oidc" {
  source = "./modules/github_oidc"
  count  = var.enable_github_oidc ? 1 : 0

  owner_github                    = var.owner_github
  repo_github                     = var.repo_github
  branches_plan_github            = var.branches_plan_github
  allow_pull_requests_plan_github = var.allow_pull_requests_plan_github
  name_prefix                     = local.name_prefix
  tf_state_bucket_arn             = var.tf_state_bucket_arn
  tf_state_bucket_cmk_arn         = var.tf_state_bucket_cmk_arn
  tf_state_lock_table_arn         = var.tf_state_lock_table_arn
  primary_region                  = var.primary_region
  account_id                      = data.aws_caller_identity.current.account_id
  secrets_manager_cmk_arn         = module.security.secrets_manager_cmk_arn
  lambda_cmk_arn                  = module.security.lambda_cmk_arn
  enable_apply_role_github        = var.enable_apply_role_github
  branches_apply_github           = var.branches_apply_github
  environment_apply_github        = var.environment_apply_github
}