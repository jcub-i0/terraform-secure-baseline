output "compliance_topic_arn" {
  value = aws_sns_topic.compliance.arn
}

output "secops_topic_arn" {
  value = aws_sns_topic.secops.arn
}

output "sec_notifs_eventbridge_dlq_arn" {
  value = aws_sqs_queue.security_notifications_eventbridge_dlq.arn
}

output "ecs_task_deficit_alarms" {
  description = "ECS task-deficit CloudWatch alarms keyed by service name."

  value = {
    for service_name, alarm in aws_cloudwatch_metric_alarm.ecs_task_deficit :
    service_name => {
      arn  = alarm.arn
      name = alarm.alarm_name
    }
  }
}

output "ecs_ingress_unhealthy_target_alarms" {
  description = "ECS ingress unhealthy-target CloudWatch alarms keyed by service name."

  value = {
    for service_name, alarm in aws_cloudwatch_metric_alarm.ecs_ingress_unhealthy_targets :
    service_name => {
      arn  = alarm.arn
      name = alarm.alarm_name
    }
  }
}