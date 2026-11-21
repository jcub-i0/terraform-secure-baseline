resource "aws_scheduler_schedule_group" "jobs" {
  count = length(var.schedules) > 0 ? 1 : 0

  name = "${var.name_prefix}-job-schedules"

  tags = {
    Name        = "${var.name_prefix}-job-schedules"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_sqs_queue" "scheduler_dlq" {
  for_each = var.schedules

  name = "${var.name_prefix}-${each.key}-scheduler-dlq"

  kms_master_key_id = var.dlq_kms_key_arn

  # Maximum SQS retention period: 14 days.
  message_retention_seconds = 1209600

  tags = {
    Name        = "${var.name_prefix}-${each.key}-scheduler-dlq"
    Environment = var.environment
    Terraform   = "true"
  }
}