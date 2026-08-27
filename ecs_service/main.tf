resource "aws_security_group" "task_security_groups" {
  for_each = var.services

  name        = "${var.name_prefix}-${each.key}-ECS-Task-SG"
  description = "Security Group for ECS service ${each.key}"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.name_prefix}-${each.key}-ECS-Task-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}