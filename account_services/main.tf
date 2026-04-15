#################
# PLATFORM STACK
#################

# CONFIG SERVICE-LINKED ROLE
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

# IAM ACCESS ANALYZER
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${var.cloud_name}-account-access-analyzer"
  type          = "ACCOUNT"

  tags = {
    Terraform = "true"
  }
}

# GUARDDUTY DETECTOR
resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  region                       = var.primary_region

  tags = {
    Name      = "${var.cloud_name}-Main"
    Terraform = "true"
  }
}