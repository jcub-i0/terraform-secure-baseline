resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  aws_service_access_principals = []
  enabled_policy_types = []
}