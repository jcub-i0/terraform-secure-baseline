output "cluster_arn" {
  description = "ARN of the ECS cluster"
  value = aws_ecs_cluster.cluster.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value = aws_ecs_cluster.cluster.name
}