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