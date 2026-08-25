#####################
# ECS_CLUSTER MODULE
#####################
resource "aws_ecs_cluster" "cluster" {
  name = "${var.name_prefix}-ecs"

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  tags = {
    Name        = "${var.name_prefix}-ecs"
    Environment = var.environment
    Terraform   = "true"
  }
}