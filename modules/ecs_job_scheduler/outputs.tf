output "schedule_group" {
  description = "Scheduler group metadata; null when no schedules are configured."

  value = length(aws_scheduler_schedule_group.jobs) > 0 ? {
    name = aws_scheduler_schedule_group.jobs[0].name
    arn  = aws_scheduler_schedule_group.jobs[0].arn
  } : null
}

output "schedules" {
  description = "Schedule and delivery-failure metadata keyed by schedule name."

  value = {
    for schedule_name, schedule in aws_scheduler_schedule.jobs :
    schedule_name => {
      arn                = schedule.arn
      name               = schedule.name
      state              = schedule.state
      job_key            = var.schedules[schedule_name].job_key
      execution_role_arn = aws_iam_role.scheduler_execution[schedule_name].arn

      dlq_arn  = aws_sqs_queue.scheduler_dlq[schedule_name].arn
      dlq_url  = aws_sqs_queue.scheduler_dlq[schedule_name].url
      dlq_name = aws_sqs_queue.scheduler_dlq[schedule_name].name

      dlq_alarm_name = aws_cloudwatch_metric_alarm.scheduler_dlq_visible[schedule_name].alarm_name
    }
  }
}