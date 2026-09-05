output "cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.cluster.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.cluster.name
}

output "container_insights" {
  description = "Configured ECS Container Insights setting"
  value = one([
    for setting in aws_ecs_cluster.cluster.setting :
    setting.value
    if setting.name == "containerInsights"
  ])
}

output "container_insights_log_group" {
  description = "Terraform-managed Container Insights performance log-group metadata; null when Container Insights is disabled"

  value = var.container_insights == "disabled" ? null : {
    arn               = aws_cloudwatch_log_group.container_insights_performance[0].arn
    name              = aws_cloudwatch_log_group.container_insights_performance[0].name
    retention_in_days = aws_cloudwatch_log_group.container_insights_performance[0].retention_in_days
    kms_key_id        = aws_cloudwatch_log_group.container_insights_performance[0].kms_key_id
  }
}