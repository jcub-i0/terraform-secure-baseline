cloud_name     = "tf-secure-baseline"
environment    = "control-plane"
primary_region = "us-east-1"

enable_github_oidc = true

# GitHub-Plan Role-related variables
branches_plan_github = ["main"]

# GitHub-Apply Role-related variables
enable_apply_role_github = true
branches_apply_github    = ["main"]
environment_apply_github = "control-plane"