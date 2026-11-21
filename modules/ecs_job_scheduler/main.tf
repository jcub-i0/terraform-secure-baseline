resource "aws_scheduler_schedule_group" "jobs" {
  count = length(var.schedules) > 0 ? 1 : 0

  name = "${var.name_prefix}-job-schedules"

  tags = {
    Name        = "${var.name_prefix}-job-schedules"
    Environment = var.environment
    Terraform   = "true"
  }
}