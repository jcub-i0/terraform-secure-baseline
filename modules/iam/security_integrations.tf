#############################################
# SECURITY SERVICE INTEGRATIONS
#
# Roles and policies used by AWS security
# services to interact with other resources
# in the environment.
#############################################

# IAM ACCESS ANALYZER
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${var.name_prefix}-account-access-analyzer"
  type          = "ACCOUNT"

  tags = {
    Terraform = "true"
  }
}
