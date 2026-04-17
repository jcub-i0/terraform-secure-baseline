cloud_name              = "tf-secure-baseline"
environment             = "prod"
primary_region          = "us-east-1"
enable_github_oidc      = false
owner_github            = null
repo_github             = null
tf_state_bucket_arn     = null
tf_state_bucket_cmk_arn = null
tf_state_lock_table_arn = null

# GitHub-Plan Role-related variables
branches_plan_github            = ["main"]
allow_pull_requests_plan_github = false

# GitHub-Apply Role-related variables
enable_apply_role_github = false
branches_apply_github    = ["main"]
environment_apply_github = null
lambda_cmk_arn           = null
secrets_manager_cmk_arn  = null