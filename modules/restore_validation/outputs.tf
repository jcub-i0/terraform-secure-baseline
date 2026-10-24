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