module "github_oidc" {
  source = "./github_oidc"
  count  = var.enable_github_oidc ? 1 : 0

  owner_github               = var.owner_github
  repo_github                = var.repo_github
  branches_github            = var.branches_github
  allow_pull_requests_github = var.allow_pull_requests_github
  github_oidc_provider_arn   = var.github_oidc_provider_arn
  name_prefix                = var.name_prefix
  tf_state_bucket_arn        = var.tf_state_bucket_arn
  tf_state_lock_table_arn    = var.tf_state_lock_table_arn
  primary_region             = var.primary_region
  account_id                 = var.account_id
  secrets_manager_cmk_arn    = var.secrets_manager_cmk_arn
}