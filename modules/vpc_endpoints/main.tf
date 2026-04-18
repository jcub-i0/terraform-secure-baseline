locals {
  interface_endpoint_subnets         = var.compute_private_subnet_ids_map
  interface_endpoint_route_table_ids = var.compute_private_route_table_ids_map
  endpoint_subnet_cidrs = flatten([
    var.subnet_cidrs["compute_private"]
  ])

  interface_endpoints = [
    "sts",
    "logs",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
    "kms",
    "config",
    "sns",
    "ec2",
    "events",
    "securityhub",
    "lambda"
  ]
}

# GATEWAY ENDPOINTS (S3, DYNAMODB)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.primary_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = values(local.interface_endpoint_route_table_ids)

  tags = {
    Name        = "${var.name_prefix}-S3-Gateway-Endpoint"
    Environment = var.environment
    Terraform   = "true"
  }
}

# INTERFACE ENDPOINTS

## SECURITY GROUP FOR ALL INTERFACE VPC ENDPOINTS
resource "aws_security_group" "interface_endpoints_sg" {
  name                   = "${var.name_prefix}-vpc-endpoints-sg"
  description            = "Security Group for Interface VPC Endpoints (AWS PrivateLink)"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.name_prefix}-VPC-Endpoints-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.primary_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(local.interface_endpoint_subnets)
  security_group_ids  = [aws_security_group.interface_endpoints_sg.id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.name_prefix}-VPC-Endpoint-${each.key}"
    Environment = var.environment
    Terraform   = "true"
  }
}