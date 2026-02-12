# SECURITY GROUP RULES

## INTERFACE VPC ENDPOINT SG RULES
resource "aws_security_group_rule" "endpoints_ingress_from_compute" {
  type                     = "ingress"
  security_group_id        = var.interface_endpoints_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.compute_sg_id
  description              = "Compute to Interface VPC Endpoints over HTTPS"
}

resource "aws_security_group_rule" "endpoints_ingress_from_lambda_isolation" {
  type                     = "ingress"
  security_group_id        = var.interface_endpoints_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.lambda_ec2_isolation_sg_id
  description              = "Lambda EC2 Isolation to Interface VPC Endpoints over HTTPS"
}

resource "aws_security_group_rule" "endpoints_ingress_from_lambda_rollback" {
  type                     = "ingress"
  security_group_id        = var.interface_endpoints_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.lambda_ec2_rollback_sg_id
  description              = "Lambda EC2 Rollback to Interface VPC Endpoints over HTTPS"
}

resource "aws_security_group_rule" "endpoints_egress_any" {
  type              = "egress"
  security_group_id = var.interface_endpoints_sg_id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Endpoint ENIs to AWS services 443"
}

## COMPUTE SG RULES
resource "aws_security_group_rule" "compute_egress_to_endpoints" {
  type                     = "egress"
  security_group_id        = var.compute_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.interface_endpoints_sg_id
  description              = "Compute to VPC Endpoints over HTTPS"
}

resource "aws_security_group_rule" "compute_egress_to_db" {
  type                     = "egress"
  security_group_id        = var.compute_sg_id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = var.data_sg_id
  description              = "Compute to DB"
}

## DATA SG RULES
resource "aws_security_group_rule" "db_ingress_from_compute" {
  type                     = "ingress"
  security_group_id        = var.data_sg_id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = var.data_sg_id
  description              = "Compute to DB"
}

## LAMBDA EC2 ISOLATION SG RULES
resource "aws_security_group_rule" "lambda_isolation_egress_to_endpoints" {
  type                     = "egress"
  security_group_id        = var.lambda_ec2_isolation_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.lambda_ec2_isolation_sg_id
  description              = "Lambda EC2 Isolation to VPC Endpoints over HTTPS"
}

## LAMBDA EC2 ROLLBACK SG RULES
resource "aws_security_group_rule" "lambda_rollback_egress_to_endpoints" {
  type                     = "egress"
  security_group_id        = var.lambda_ec2_rollback_sg_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.lambda_ec2_rollback_sg_id
  description              = "Lambda EC2 Rollback to VPC Endpoints over HTTPS"
}