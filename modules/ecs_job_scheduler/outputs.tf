output "schedule_group" {
  description = "Scheduler group metadata; null when no schedules are configured."

  value = length(aws_scheduler_schedule_group.jobs) > 0 ? {
    name = aws_scheduler_schedule_group.jobs[0].name
    arn  = aws_scheduler_schedule_group.jobs[0].arn
  } : null
}