module "github_oidc" {
  source = "./github_oidc"
  count  = var.enable_github_oidc ? 1 : 0

  github_owner               = var.github_owner
  github_repo                = var.github_repo
  github_branches            = var.github_branches
  github_allow_pull_requests = var.github_allow_pull_requests
  github_oidc_provider_arn   = var.github_oidc_provider_arn
  name_prefix                = var.name_prefix
  tf_state_bucket_arn        = var.tf_state_bucket_arn
  tf_state_lock_table_arn = var.tf_state_lock_table_arn
}