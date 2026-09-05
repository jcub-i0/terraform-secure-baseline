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

resource "aws_cloudwatch_log_group" "container_insights_performance" {
  count = var.container_insights == "disabled" ? 0 : 1

  name = "/aws/ecs/containerinsights/${var.name_prefix}-ecs/performance"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id = var.logs_cmk_arn

  tags = {
    Name        = "/aws/ecs/containerinsights/${var.name_prefix}-ecs/performance"
    Environment = var.environment
    Terraform   = "true"
  }
}