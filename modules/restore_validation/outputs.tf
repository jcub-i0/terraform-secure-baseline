output "coordinator_lambda_arn" {
  value = aws_lambda_function.coordinator.arn
}

output "worker_lambda_arn" {
  value = aws_lambda_function.worker.arn
}

output "restore_validation_worker_sg_id" {
  value = aws_security_group.worker.id
}

output "event_rule_arn" {
  value = aws_cloudwatch_event_rule.restore_completed.arn
}

output "validation_dlq_arn" {
  value = aws_sqs_queue.validation_dlq.arn
}

output "restore_validation_coordinator_log_group_name" {
  description = "CloudWatch Logs group name for the Restore Validation coordinator."
  value       = aws_cloudwatch_log_group.coordinator.name
}

output "restore_validation_worker_log_group_name" {
  description = "CloudWatch Logs group name for the Restore Validation SQL worker."
  value       = aws_cloudwatch_log_group.worker.name
}

output "alarm_names" {
  description = "CloudWatch alarms protecting Restore Validation."

  value = {
    validation_dlq = (
      aws_cloudwatch_metric_alarm.validation_dlq_messages.alarm_name
    )

    lambda_errors = {
      for name, alarm in aws_cloudwatch_metric_alarm.lambda_errors :
      name => alarm.alarm_name
    }

    validation_failed = (
      aws_cloudwatch_metric_alarm.validation_failed.alarm_name
    )
  }
}