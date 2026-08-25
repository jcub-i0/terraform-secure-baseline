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

resource "aws_security_group_rule" "https_ingress" {
  type = "ingress"
  security_group_id = aws_security_group.load_balancer.id
  from_port = 443
  to_port = 443
  protocol = "tcp"
  cidr_blocks = var.ingress_cidrs
  description = "Allow HTTPS ingress to the Application Load Balancer"
}