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
  type              = "ingress"
  security_group_id = aws_security_group.load_balancer.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.ingress_cidrs
  description       = "Allow HTTPS ingress to the Application Load Balancer"
}

resource "aws_lb" "load_balancer" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.load_balancer.id,
  ]

  subnets = var.public_subnet_ids

  enable_deletion_protection = false # CHANGE THIS IN PROD
  drop_invalid_header_fields = true

  tags = {
    Name        = "${var.name_prefix}-alb"
    Environment = var.environment
    Terraform   = "true"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-alb") <= 32
      error_message = "The complete Application Load Balancer name must not exceed 32 characters."
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"not_found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_target_group" "target_groups" {
  for_each = var.services

  name        = "${var.name_prefix}-${each.key}"
  port        = each.value.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled  = true
    protocol = "HTTP"
    path     = each.value.health_check_path
    matcher  = "200-399"
  }

  tags = {
    Name        = "${var.name_prefix}-${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }

  lifecycle {
    precondition {
      condition     = length("${var.name_prefix}-${each.key}") <= 32
      error_message = "The complete target group name must not exceed 32 characters."
    }
  }
}