resource "aws_security_group" "load_balancer" {
  name        = "${var.name_prefix}-ALB-SG"
  description = "Security Group for the Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name        = "${var.name_prefix}-ALB-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}