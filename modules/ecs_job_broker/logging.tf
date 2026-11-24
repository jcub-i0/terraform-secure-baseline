resource "aws_cloudwatch_log_group" "broker" {
  count = length(var.jobs) > 0 ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-job-broker"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.broker_log_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-job-broker-logs"
    Environment = var.environment
    Terraform   = "true"
  }
}
