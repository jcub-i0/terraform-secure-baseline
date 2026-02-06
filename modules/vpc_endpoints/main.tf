locals {
  endpoint_subnets = var.compute_private_subnet_ids_map

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
    "sns"
  ]
}

# GET ROUTE TABLE FOR EACH PRIVATE SUBNET
data "aws_route_table" "endpoint" {
  for_each  = local.endpoint_subnets
  subnet_id = each.value
}

# GATEWAY ENDPOINTS (S3, DYNAMODB)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.primary_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [for rt in values(data.aws_route_table.endpoint) : rt.id]

  tags = {
    Name      = "S3-Gateway-Endpoint"
    Terraform = "true"
  }
}

# INTERFACE ENDPOINTS

## SECURITY GROUP FOR ALL INTERFACE VPC ENDPOINTS
resource "aws_security_group" "interface_endpoints_sg" {
  name        = "vpc-endpoints-sg"
  description = "Security Group for Interface VPC Endpoints (AWS PrivateLink)"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.endpoint_subnet_cidrs
    description = "Allow AWS services to communicate with VPC Endpoints"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.endpoint_subnet_cidrs
    description = "Allow VPC Endpoints to communicate with AWS services"
  }

  tags = {
    Name      = "VPC-Endpoints-SG"
    Terraform = "true"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.primary_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(local.endpoint_subnets)
  security_group_ids  = [aws_security_group.interface_endpoints_sg.id]
  private_dns_enabled = true
  tags = {
    Name      = "VPC-Endpoint-${each.key}"
    Terraform = "true"
  }
}