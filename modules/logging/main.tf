# CLOUDWATCH
## CLOUDWATCH LOG GROUP
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name = "/aws/cloudtrail/tf-secure-baseline"
  retention_in_days = 90
  kms_key_id = var.logs_kms_key_arn
}